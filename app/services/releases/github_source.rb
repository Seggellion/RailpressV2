# frozen_string_literal: true

require "railpress/releases"
require "net/http"
require "timeout"
module Releases
  # Unauthenticated public metadata. No commit/main polling or remote code loading.
  class GithubSource
    REPOSITORY = "Seggellion/RailpressV2"
    ENDPOINT = "https://api.github.com/repos/#{REPOSITORY}/releases?per_page=20"
    HOSTS = %w[api.github.com github.com release-assets.githubusercontent.com].freeze
    NAMES = %w[manifest.json signature.json package.tar.gz native-plan.json].freeze
    class Failure < StandardError; end
    def initialize(resolver: ->(host) { Resolv.getaddresses(host) }, cert_store: nil)
      @resolver, @cert_store = resolver, cert_store
    end
    def get(url, limit:)
      Timeout.timeout(5) do
        3.times do
          uri = URI.parse(url)
          raise Failure, "unexpected_destination" unless uri.is_a?(URI::HTTPS) && HOSTS.include?(uri.host) && uri.port == 443 && !uri.userinfo && !uri.fragment
          target = Seo::HttpTargetGuard.new(origin: "https://#{uri.host}", allowed_urls: [ url ], resolver: @resolver).call(url)
          http = Net::HTTP.new(uri.host, 443, nil)
          http.ipaddr = target.ip_address
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.verify_hostname = true
          http.cert_store = @cert_store if @cert_store
          http.open_timeout = 2; http.read_timeout = 3; http.write_timeout = 2; http.max_retries = 0
          response = nil; body = +"".b
          headers = { "Accept" => url == ENDPOINT ? "application/vnd.github+json" : "application/octet-stream", "Accept-Encoding" => "identity",
            "User-Agent" => "Railpress/#{Railpress::Product::VERSION}", "X-GitHub-Api-Version" => "2022-11-28" }
          http.start do |connection|
            socket = connection.instance_variable_get(:@socket)
            budget = Seo::NetHttpClient::ReadBudgetIO.new(socket.io)
            connection.instance_variable_set(:@socket, Net::BufferedIO.new(budget, read_timeout: 3, write_timeout: 2))
            connection.request(Net::HTTP::Get.new(uri.request_uri, headers)) do |incoming|
              response = incoming
              raise Failure, "response_headers" if incoming.to_hash.sum { |key, values| key.bytesize + values.sum(&:bytesize) } > 16_384
              raise Failure, "response_encoding" unless [ nil, "", "identity" ].include?(incoming["content-encoding"])
              raise Failure, "response_limit" if incoming["content-length"].to_i > limit
              budget.body!(limit + 32_768)
              incoming.read_body { |chunk| raise(Failure, "response_limit") if body.bytesize + chunk.bytesize > limit; body << chunk }
            end
          end
          return body if response.code == "200"
          raise Failure, "provider_status" unless %w[301 302 303 307 308].include?(response.code)
          url = URI.join(url, response["location"].to_s).to_s
        end
        raise Failure, "redirect_limit"
      end
    rescue Failure
      raise
    rescue StandardError
      raise Failure, "verified_github_unavailable", cause: nil
    end
    def releases
      rows = Railpress::Releases.parse(get(ENDPOINT, limit: 1024 * 1024))
      raise Failure, "release_inventory" unless rows.is_a?(Array) && rows.length <= 20
      rows.filter_map do |row|
        next unless row.is_a?(Hash) && row["draft"] == false && row["published_at"].is_a?(String)
        tag = row["tag_name"]
        next unless tag.is_a?(String) && tag.start_with?("v") && Railpress::Releases::SEMVER.match?(tag.delete_prefix("v"))
        version = tag.delete_prefix("v")
        next unless row["prerelease"] == version.split("+").first.include?("-")
        assets = row["assets"]
        next unless assets.is_a?(Array) && assets.length <= 64
        chosen = NAMES.to_h do |name|
          found = assets.select { |asset| asset.is_a?(Hash) && asset["name"] == name && asset["state"] == "uploaded" }
          next [ name, nil ] unless found.length == 1
          asset = found.first
          expected = "https://github.com/#{REPOSITORY}/releases/download/#{tag}/#{name}"
          next [ name, nil ] unless asset["browser_download_url"] == expected && asset["size"].is_a?(Integer) && asset["size"].positive?
          [ name, { "url" => expected, "size" => asset["size"] } ]
        end
        next if chosen.values.any?(&:nil?)
        next if chosen["manifest.json"]["size"] > 1024 * 1024 || chosen["signature.json"]["size"] > 4096 || chosen["native-plan.json"]["size"] > 65_536 || chosen["package.tar.gz"]["size"] > Railpress::Releases::Manifest::MAX_PACKAGE
        { "version" => version, "tag" => tag, "assets" => chosen }
      end.sort { |a, b| -Railpress::Releases.compare_versions(a["version"], b["version"]) }.first(5)
    end
    def metadata(row)
      { "manifest" => Railpress::Releases.parse(get(row.fetch("assets").fetch("manifest.json").fetch("url"), limit: 1024 * 1024)),
        "signature" => Railpress::Releases.parse(get(row.fetch("assets").fetch("signature.json").fetch("url"), limit: 4096)),
        "version" => row.fetch("version"), "package_url" => row.fetch("assets").fetch("package.tar.gz").fetch("url"),
        "plan_url" => row.fetch("assets").fetch("native-plan.json").fetch("url") }
    end
  end
end
