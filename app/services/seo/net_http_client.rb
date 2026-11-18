# frozen_string_literal: true

# Adapted from UltimaCraft a6e17605689442a91e697eae0584a0c2bf84f4bf; MIT (c) 2024-2026 Dustin Hill.
# See THIRD_PARTY_NOTICES.md. Railpress applies stricter scope and resource limits.

require "net/http"
require "openssl"
require "timeout"
require "delegate"
module Seo
  class NetHttpClient
    Response = Data.define(:status, :headers, :body) do
      def header(name) = headers[name.to_s.downcase]&.first
    end
    class TimeoutError < StandardError; end
    class NetworkError < StandardError; end
    class ResponseTooLarge < StandardError; end
    # Instance-only adapter for the pinned native Net::HTTP transport. It caps
    # plaintext socket bytes before the HTTP parser allocates a header line.
    class ReadBudgetIO < SimpleDelegator
      def initialize(io)
        super(io)
        @read_bytes = 0
        @maximum = 16_384
      end
      def body!(maximum)
        @maximum = maximum
      end
      def read_nonblock(length, buffer = nil, exception: true)
        remaining = @maximum - @read_bytes
        raise ResponseTooLarge unless remaining.positive?
        value = __getobj__.read_nonblock([ length, remaining ].min, buffer, exception: exception)
        @read_bytes += value.bytesize if value.is_a?(String)
        value
      end
    end
    def initialize(connect_timeout: 2, read_timeout: 2, total_timeout: 8, response_byte_limit: 512*1024, cert_store: nil)
      @connect_timeout, @read_timeout, @total_timeout, @limit, @cert_store = connect_timeout, read_timeout, total_timeout, response_byte_limit, cert_store
    end
    def get(uri:, ip_address:)
      response, body = nil, +"".b
      Timeout.timeout(@total_timeout) do
        request = Net::HTTP::Get.new(uri.request_uri.presence || "/", "Accept" => "text/html,application/xhtml+xml", "Accept-Encoding" => "identity", "User-Agent" => "Railpress-SEO-Diagnostics/1")
        http = Net::HTTP.new(uri.hostname, uri.port, nil)
        http.ipaddr = ip_address
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true
        http.cert_store = @cert_store if @cert_store
        http.open_timeout, http.read_timeout, http.write_timeout = @connect_timeout, @read_timeout, @connect_timeout
        http.max_retries = 0
        http.start do |connection|
          transport = connection.instance_variable_get(:@socket)
          budget = ReadBudgetIO.new(transport.io)
          connection.instance_variable_set(:@socket, Net::BufferedIO.new(budget, read_timeout: @read_timeout, write_timeout: @connect_timeout))
          connection.request(request) do |incoming|
            response = incoming
            raise ResponseTooLarge if incoming.to_hash.sum { |key, values| key.bytesize + values.sum(&:bytesize) } > 16_384
            raise ResponseTooLarge unless [ nil, "", "identity" ].include?(incoming["content-encoding"])
            raise ResponseTooLarge if incoming["content-length"].to_i > @limit
            budget.body!(@limit + 32_768)
            incoming.read_body do |chunk|
              raise ResponseTooLarge if body.bytesize + chunk.bytesize > @limit
              body << chunk
            end
          end
        end
      end
      Response.new(status: response.code.to_i, headers: response.to_hash.transform_keys(&:downcase).freeze, body: body.freeze)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
      raise TimeoutError, "bounded_http_timeout"
    rescue ResponseTooLarge
      raise
    rescue SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      raise NetworkError, "verified_http_unavailable"
    end
  end
end
