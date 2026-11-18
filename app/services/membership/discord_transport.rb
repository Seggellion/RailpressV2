require "net/http"
require "openssl"
require "timeout"
module Membership
  class DiscordTransport
    URLS = %w[https://discord.com/api/oauth2/token https://discord.com/api/oauth2/token/revoke https://discord.com/api/v10/users/@me].freeze
    def initialize(resolver: nil)
      options = { origin: "https://discord.com", allowed_urls: URLS }
      options[:resolver] = resolver if resolver
      @guard = Seo::HttpTargetGuard.new(**options)
    end
    def request(url, form: nil, bearer: nil, empty: false)
      raise Invalid unless URLS.include?(url) && ((form && !bearer) || (bearer && !form))
      target = @guard.call(url)
      body = +"".b
      status = nil
      Timeout.timeout(5) do
        http = Net::HTTP.new(target.uri.hostname, 443, nil)
        http.ipaddr = target.ip_address
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true
        http.open_timeout = http.read_timeout = http.write_timeout = 2
        http.max_retries = 0
        request = form ? Net::HTTP::Post.new(target.uri.request_uri) : Net::HTTP::Get.new(target.uri.request_uri)
        request["Accept"] = "application/json"
        request["Accept-Encoding"] = "identity"
        request["Authorization"] = "Bearer #{bearer}" if bearer
        request.set_form_data(form) if form
        http.start do |connection|
          transport = connection.instance_variable_get(:@socket)
          budget = Seo::NetHttpClient::ReadBudgetIO.new(transport.io)
          connection.instance_variable_set(:@socket, Net::BufferedIO.new(budget, read_timeout: 2, write_timeout: 2))
          connection.request(request) do |response|
            status = response.code.to_i
            raise Unavailable unless status == 200 && [ nil, "", "identity" ].include?(response["content-encoding"]) && response["content-length"].to_i <= 16_384
            raise Unavailable unless empty || response["content-type"].to_s.split(";").first == "application/json"
            budget.body!(49_152)
            response.read_body { |chunk| raise Unavailable if body.bytesize + chunk.bytesize > 16_384; body << chunk }
          end
        end
      end
      return {} if empty && body.empty?
      value = JSON.parse(body, max_nesting: 8)
      raise Invalid unless value.is_a?(Hash)
      value
    rescue StandardError
      raise Unavailable, "Discord is unavailable; no account change was accepted", cause: nil
    end
  end
end
