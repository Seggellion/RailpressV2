# frozen_string_literal: true

module Railpress
  module Extensions
    class Registry
      attr_reader :engine_set, :engines

      def self.empty = new(nil, {})

      def self.load(engine_set)
        namespaces = engine_set.entries.values.map { |entry| entry.manifest.engine.split("::").first }
        unless namespaces.uniq == namespaces && namespaces.none? { |name| Object.const_defined?(name, false) }
          raise Invalid, "extension_namespace_already_loaded"
        end
        engines = engine_set.entries.to_h do |id, entry|
          namespace, engine_name = entry.manifest.engine.split("::")
          require entry.entrypoint
          mod = Object.const_get(namespace, false)
          engine = mod.const_get(engine_name, false)
          raise Invalid, "extension_engine_type" unless engine.is_a?(Class) && engine < Rails::Engine && !(engine < Rails::Application) && engine.isolated? &&
            File.realpath(engine.instance.root.to_s) == entry.root
          [ id, engine ]
        end
        new(engine_set, engines)
      rescue NameError, LoadError, SystemCallError
        raise Invalid, "extension_engine_load", cause: nil
      end

      def initialize(engine_set, engines)
        @engine_set = engine_set
        @engines = engines.freeze
        freeze
      end

      def entries = engine_set ? engine_set.entries : {}.freeze
      def generation = engine_set ? engine_set.generation : 0
      def fingerprint = engine_set ? engine_set.fingerprint : EngineSet::EMPTY_FINGERPRINT
      def site = engine_set&.site
      def trust = engine_set&.trust

      def mount(mapper)
        engines.each do |id, engine|
          routes = entries.fetch(id).manifest.routes
          key = id.tr("-", "_")
          if routes["public"]
            mapper.mount endpoint(engine, id, admin: false), at: public_path(id), as: "extension_#{key}"
          end
          if routes["admin"]
            mapper.mount endpoint(engine, id, admin: true), at: admin_path(id), as: "extension_admin_#{key}"
          end
        end
      end

      def public_path(id) = "/extensions/#{id}"
      def admin_path(id) = "/admin/modules/#{id}/manage"

      def reserved?(path)
        match = path.match(/\A\/extensions\/([^\/]+)(?:\/|\z)/)
        match && entries[match[1]]&.manifest&.routes&.fetch("public")
      end

      private

      def endpoint(engine, id, admin:)
        lambda do |env|
          if !::Extensions::Activation.enabled?(id, registry: self)
            # Existing CMS content may legitimately precede an inactive mount.
            blocked(404, cascade: !admin)
          elsif !allowed_methods(id).include?(env["REQUEST_METHOD"])
            blocked(405, methods: allowed_methods(id))
          elsif env["REQUEST_METHOD"] == "POST" && !Railpress::SecureTransport.secure?(env)
            blocked(403)
          elsif admin && !admin_request?(env, id)
            blocked(403)
          else
            # The outer Rails session middleware commits CSRF state from this
            # same Rack environment after the mounted controller returns.
            env["railpress.extension.id"] = id
            env["railpress.extension.mount"] = admin ? "admin" : "public"
            status, headers, body = engine.call(env)
            [ status, headers.merge("cache-control" => "no-store", "x-robots-tag" => "noindex, nofollow"), body ]
          end
        rescue ActiveRecord::ActiveRecordError, Railpress::SecurityClock::Unavailable
          blocked(503)
        end
      end

      def allowed_methods(id)
        declares?(id, "forms") ? %w[GET HEAD POST] : %w[GET HEAD]
      end

      def declares?(id, feature)
        entries.fetch(id).manifest.data.fetch("provides").include?("#{id}.#{feature}")
      end

      def admin_request?(env, id)
        return false unless Railpress::SecureTransport.secure?(env)
        actor = UserSession.resolve(env["rack.session"]&.[](:authentication_token))&.user
        Identity::Capabilities.allowed?(actor, :manage_modules) ||
          (declares?(id, "reviews") && Identity::Capabilities.allowed?(actor, :review_extension_records))
      end

      def blocked(status, cascade: false, methods: [])
        headers = { "content-type" => "text/plain", "cache-control" => "no-store", "x-robots-tag" => "noindex, nofollow" }
        headers["x-cascade"] = "pass" if cascade
        headers["allow"] = methods.join(", ") if status == 405
        [ status, headers, [ Rack::Utils::HTTP_STATUS_CODES.fetch(status) ] ]
      end
    end
  end
end
