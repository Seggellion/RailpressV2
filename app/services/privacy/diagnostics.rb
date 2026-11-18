require "rack/mock"
require "json"
require "tempfile"

module Privacy
  module Diagnostics
    PATHS = %w[/ /blog /search /robots.txt /sitemap.xml /feed.xml /api/public/v1/news.json /privacy-diagnostic-missing].freeze
    module_function
    def fingerprint
      names = %w[app/services/privacy/public_requests.rb lib/railpress/anonymous_privacy.rb app/controllers/public_contents_controller.rb app/assets/javascripts/public_navigation.js]
      Digest::SHA256.hexdigest(names.map { |name| File.binread(Rails.root.join(name)) }.join)
    end
    def call(site)
      raise Invalid unless Railpress::BootstrapState.for_application.installed? && Current.user.nil?
      origin = URI.parse(site.canonical_origin)
      rows = PATHS.map do |path|
        result = Rack::MockRequest.new(Rails.application).get(path, "HTTPS" => "on", "HTTP_HOST" => origin.authority, "REMOTE_ADDR" => "127.0.0.1")
        fragment = Nokogiri::HTML5(result.body)
        external = fragment.css("[src],[srcset],link[href]").sum do |node|
          next 0 if node.name == "link" && !%w[stylesheet icon preload modulepreload prefetch preconnect dns-prefetch].include?(node["rel"])
          node.attributes.values.count do |attribute|
            %w[src srcset href].include?(attribute.name) && attribute.value.match?(%r{(?:https?:)?//})
          end
        end
        { "path" => path, "status" => result.status, "set_cookie" => result.headers.keys.any? { |key| key.downcase == "set-cookie" },
          "external_resource_count" => external, "connect_blocked" => result.headers["content-security-policy"].to_s.include?("connect-src 'none'"),
          "body_sha256" => Digest::SHA256.hexdigest(result.body) }
      end
      checks = rows.all? { |row| [ 200, 404 ].include?(row["status"]) && !row["set_cookie"] && row["external_resource_count"].zero? && (!site.privacy_first_anonymous? || row["connect_blocked"]) }
      { "format" => "railpress.privacy-posture.v1", "privacy_revision" => site.privacy_revision, "policy_enabled" => site.privacy_first_anonymous?,
        "fingerprint" => fingerprint, "observed_at" => Time.now.utc.iso8601, "checks_pass" => checks, "routes" => rows,
        "browser_execution" => "NOT TESTED", "host_proxy_IP_logs" => "UNKNOWN", "scope" => "Fixed-route in-process HTTP snapshot; no external network requests or legal attestation" }
    end
    def path = File.join(Railpress::BootstrapState.for_application.root, "privacy-posture.json")
    def write!(report)
      raise Invalid unless report["format"] == "railpress.privacy-posture.v1"
      data = JSON.generate(report)
      raise Invalid if data.bytesize > 65_536
      root = Railpress::BootstrapState.for_application.root
      Tempfile.create([ "privacy-posture-", ".json" ], root) do |file|
        file.chmod(0o600); file.write(data); file.flush; file.fsync
        File.rename(file.path, path)
      end
      File.open(root, File::RDONLY, &:fsync)
    end
    def read(site)
      return unless File.exist?(path)
      stat = File.lstat(path)
      return unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= 65_536
      value = JSON.parse(File.binread(path))
      return unless value.is_a?(Hash) && value["format"] == "railpress.privacy-posture.v1" && value["privacy_revision"] == site.privacy_revision && value["policy_enabled"] == site.privacy_first_anonymous? && value["fingerprint"] == fingerprint && value["routes"].is_a?(Array) && value["routes"].size == PATHS.size
      return unless value["routes"].all? { |row| row.is_a?(Hash) && PATHS.include?(row["path"]) && row["status"].is_a?(Integer) && row["external_resource_count"].is_a?(Integer) }
      value
    rescue JSON::ParserError, IOError, SystemCallError
      nil
    end
  end
end
