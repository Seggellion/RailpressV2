require "net/http"
require "openssl"
require "timeout"
module OfficialNews
  class Client
    class Failure < StandardError; end
    Response = Data.define(:status, :payload, :etag, :last_modified)
    def initialize(guard: Seo::HttpTargetGuard.new(origin: Schema::ORIGIN, allowed_urls: [ Schema::ENDPOINT ]), cert_store: nil)
      @guard, @cert_store=guard, cert_store
    end
    def self.etag(value)
      value if value.is_a?(String) && value.bytesize<=200 && value.match?(/\A(?:W\/)?"[\x21\x23-\x7e]*"\z/)
    end
    def self.modified(value)
      return unless value.is_a?(String) && value.bytesize<=100 && !value.match?(/[\r\n]/)
      Time.httpdate(value).httpdate
    rescue ArgumentError
      nil
    end
    def get(etag: nil, last_modified: nil)
      Timeout.timeout(5) do
        target=@guard.call(Schema::ENDPOINT)
        headers={ "Accept"=>"application/json", "Accept-Encoding"=>"identity", "User-Agent"=>"Railpress-OfficialNews/1" }
        headers["If-None-Match"]=self.class.etag(etag) if self.class.etag(etag)
        headers["If-Modified-Since"]=self.class.modified(last_modified) if self.class.modified(last_modified)
        request=Net::HTTP::Get.new(target.uri.request_uri, headers)
        http=Net::HTTP.new(target.uri.hostname, target.uri.port, nil)
        http.ipaddr=target.ip_address
        http.use_ssl=true
        http.verify_mode=OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname=true
        http.cert_store=@cert_store if @cert_store
        http.open_timeout=2;http.read_timeout=3;http.write_timeout=2;http.max_retries=0
        response=nil;body=+"".b
        http.start do |connection|
          transport=connection.instance_variable_get(:@socket)
          budget=Seo::NetHttpClient::ReadBudgetIO.new(transport.io)
          connection.instance_variable_set(:@socket, Net::BufferedIO.new(budget, read_timeout: 3, write_timeout: 2))
          connection.request(request) do |incoming|
            response=incoming
            raise Failure, "unexpected_status" unless %w[200 304].include?(incoming.code)
            raise Failure, "response_headers" if incoming.to_hash.sum { |key, values|key.bytesize+values.sum(&:bytesize) }>16384
            raise Failure, "response_encoding" unless [ nil, "", "identity" ].include?(incoming["content-encoding"])
            raise Failure, "oversized_feed" if incoming["content-length"].to_i>Schema::MAX_BYTES
            raise Failure, "invalid_content_type" if incoming.code=="200" && incoming["content-type"].to_s.split(";").first!="application/json"
            budget.body!(Schema::MAX_BYTES+32768)
            incoming.read_body do |chunk|
              raise Failure, "oversized_feed" if body.bytesize+chunk.bytesize>Schema::MAX_BYTES
              body<<chunk
            end
          end
        end
        Response.new(status: response.code.to_i, payload: response.code=="200" ? Schema.parse(body) : nil,
          etag: self.class.etag(response["etag"]), last_modified: self.class.modified(response["last-modified"]))
      end
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise Failure, "bounded_timeout", cause: nil
    rescue Seo::HttpTargetGuard::UnsafeTarget
      raise Failure, "unsafe_provider_address", cause: nil
    rescue Seo::NetHttpClient::ResponseTooLarge
      raise Failure, "oversized_feed", cause: nil
    rescue OpenSSL::SSL::SSLError, SocketError, IOError, SystemCallError
      raise Failure, "verified_provider_unavailable", cause: nil
    end
  end
end
