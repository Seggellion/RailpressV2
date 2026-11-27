# frozen_string_literal: true

require "json"
require "digest"
require "ipaddr"

module Railpress
  # Trusted native-host adapter. Also supports the unchanged M11 predecessor.
  # This file deliberately does not require another release's Product or models.
  class NativeWebProbe
    BUSINESS = %w[Site User Content ContentRevision Taxonomy Term ContentTerm Redirect ThemeInstallation ThemeState ThemeOverlay Menu MenuItem MenuRevision MenuLocation NavigationState MediaAsset MediaReference].freeze unless const_defined?(:BUSINESS, false)
    def initialize(app) = @app = app
    def call(env)
      return @app.call(env) unless env["PATH_INFO"] == "/health/release"
      headers = { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store",
        "x-robots-tag" => "noindex, nofollow", "x-content-type-options" => "nosniff", "content-security-policy" => "default-src 'none'; frame-ancestors 'none'" }
      expected = ENV["RAILPRESS_NATIVE_PROBE_TOKEN"]
      supplied = env["HTTP_X_RAILPRESS_PROBE"].to_s
      secure = %w[https on 1].include?(env["HTTPS"].to_s.downcase) ||
        (ENV.fetch("RAILPRESS_TLS_PROXY_IPS", "").split(",").include?(env["REMOTE_ADDR"]) && env["HTTP_X_FORWARDED_PROTO"] == "https")
      allowed = env["REQUEST_METHOD"] == "GET" && secure && expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/) &&
        supplied.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
      return [ 404, headers, [ '{"error":"not_found"}' ] ] unless allowed
      [ 200, headers, [ Rails.application.executor.wrap { JSON.generate(self.class.report) } ] ]
    rescue StandardError
      [ 503, headers || { "content-type" => "application/json", "cache-control" => "no-store" }, [ '{"error":"native_readiness_unavailable"}' ] ]
    end
    def self.news_fingerprints
      { "OfficialNewsState"=>"official_news_states", "OfficialNewsReview"=>"official_news_reviews", "DashboardDraftSubmission"=>"dashboard_draft_submissions" }.filter_map do |name, table|
        next unless ActiveRecord::Base.connection.table_exists?(table)
        model = Class.new(ActiveRecord::Base) { self.table_name = table }
        columns = name == "OfficialNewsState" ? %w[id site_id enabled provider_enabled generation] : model.column_names
        [ name, Digest::SHA256.hexdigest(Releases.canonical(model.order(:id).map { |record| record.attributes.slice(*columns) })) ]
      end.to_h
    end
    def self.report
      site = Site.find_by!(singleton_key: 1)
      state = ThemeState.first
      selected = state&.active_installation
      Themes::Storage.load(selected) if selected
      observation = Railpress::SecurityClock.for_application.sample
      { "format" => "railpress.release-health.v1", "deployment_id" => ENV["RAILPRESS_DEPLOYMENT_ID"],
        "release_id" => ENV["RAILPRESS_DEPLOYMENT_DIGEST"],
        "product" => { "version" => Railpress::Product::VERSION, "channel" => Railpress::Product::CHANNEL,
          "schema" => Railpress::Product::SCHEMA, "jobs" => Railpress::Product::JOB_PAYLOAD,
          "theme_api" => Railpress::Product::THEME_API, "configuration" => Railpress::Product::CONFIGURATION,
          "security_clock" => Railpress::Product::SECURITY_CLOCK },
        "installation_id" => site.install_id, "database_engine" => ActiveRecord::Base.connection.adapter_name,
        "theme" => selected && { "id" => selected.theme_key, "version" => selected.version, "digest" => selected.digest,
          "installation_id" => selected.id, "overlay_id" => state.active_overlay_id },
        "themes" => ::Releases::Context.respond_to?(:verified_themes) ? ::Releases::Context.verified_themes : ::Releases::Context.current.fetch("themes"),
        "engine_set_fingerprint" => defined?(Railpress::Extensions) ? Railpress::Extensions.registry.fingerprint : nil,
        "package_context" => package_context,
        "business_contract" => "railpress.native-business.v2",
        "business_fingerprints" => BUSINESS.to_h { |name|
          relation = name.constantize.order(:id)
          relation = relation.where(content_preview_id: nil) if name == "MediaReference"
          [ name, Digest::SHA256.hexdigest(Railpress::Releases.canonical(relation.map { |record| record.attributes.reject { |key, value| key.start_with?("extension_") || (key == "upload_publisher" && value.nil?) } })) ]
        }.merge(news_fingerprints),
        "password_verifier_fingerprint" => Digest::SHA256.hexdigest(Railpress::Releases.canonical(User.order(:id).pluck(:id, :password_digest))),
        "password_verifiers_preserved_by_code_update" => true,
        "user_identity_fingerprint" => Digest::SHA256.hexdigest(Railpress::Releases.canonical(User.order(:id).map { |user| user.attributes.except("auth_version") })),
        "clock_binding" => Digest::SHA256.hexdigest(observation.fetch("domain") + observation.fetch("epoch")),
        "clock_anomaly" => !observation["anomaly"].nil?, "job_contract" => Railpress::Product::JOB_PAYLOAD,
        "worker_processes" => SolidQueue::Process.order(:id).pluck(:pid, :kind) }
    end
    def self.package_context
      ::Releases::Context.local_packages if ::Releases::Context.respond_to?(:local_packages)
    rescue Railpress::Releases::Invalid
      nil
    end
  end
end
