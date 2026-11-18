# frozen_string_literal: true

module Railpress
  module NativeHost
    class Probe
      def initialize(config) = @config = config
      def request(path, slot: nil, token: false)
        raise Error, "probe_path" unless path.is_a?(String) && path.start_with?("/") && path.bytesize <= 1024 && !path.match?(/[\r\n\x00]/)
        port = slot.nil? ? @config.data["edge_port"] : @config.data["puma_ports"].fetch(slot)
        http = Net::HTTP.new("localhost", port, nil)
        http.open_timeout = 2
        http.read_timeout = 3
        http.write_timeout = 3
        if slot.nil?
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.ca_file = @config.path("proxy", "cert.pem")
        end
        headers = { "Host" => "localhost:#{@config.data['edge_port']}", "Connection" => "close" }
        headers["X-Forwarded-Proto"] = "https" unless slot.nil?
        headers["X-Railpress-Probe"] = @config.app_environment.fetch("RAILPRESS_NATIVE_PROBE_TOKEN") if token
        body = +""
        response = nil
        Timeout.timeout(5) do
          http.start do |connection|
            connection.request(Net::HTTP::Get.new(path, headers)) do |result|
              response = result
              result.read_body do |chunk|
                body << chunk
                raise Error, "probe_response_limit" if body.bytesize > 524_288
              end
            end
          end
        end
        { "status" => response.code.to_i, "body" => body, "headers" => response.to_hash }
      rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
        raise Error, "release_probe_unavailable"
      end
      def health(slot: nil)
        result = request("/health/release", slot: slot, token: true)
        raise Error, "candidate_health_status" unless result["status"] == 200 &&
          result["headers"].fetch("cache-control", []).join.include?("no-store")
        Releases.parse(result["body"], limit: 524_288)
      end
      def identity!(report, id, manifest, allow_clock_hold: false)
        raise Error, "candidate_identity" unless report["format"] == "railpress.release-health.v1" &&
          report["deployment_id"] == @config.data["deployment_id"] && report["installation_id"] == @config.data["install_id"] &&
          report["release_id"] == id && report.dig("product", "version") == manifest["version"] &&
          report.dig("product", "security_clock") == 2 && report["business_fingerprints"].is_a?(Hash) &&
          Releases::SHA.match?(report["clock_binding"].to_s)
        raise Error, "candidate_clock_anomaly" if report["clock_anomaly"] && !allow_clock_hold
        report
      end
    end
  end
end
