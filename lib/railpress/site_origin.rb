require "uri"
require "ipaddr"
module Railpress
  class SiteOrigin
    class Invalid < StandardError; end
    attr_reader :value
    def initialize(value)
      uri = URI.parse(value.to_s)
      host = uri.host.to_s
      valid_host = host.bytesize <= 253 && host.match?(/\A(?:[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?|\[[0-9a-fA-F:]+\])\z/)
      if host.start_with?("[") || host.match?(/\A[0-9.]+\z/)
        IPAddr.new(host.delete_prefix("[").delete_suffix("]"))
      else
        valid_host &&= host.split(".", -1).all? { |label| label.match?(/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/) }
      end
      raise Invalid unless uri.is_a?(URI::HTTPS) && valid_host && !uri.userinfo && [ "", "/" ].include?(uri.path) && !uri.query && !uri.fragment && uri.port.between?(1, 65535)
      @value = "https://#{host.downcase}#{uri.port == 443 ? "" : ":#{uri.port}"}".freeze
      freeze
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError, ArgumentError
      raise Invalid, "Use a valid HTTPS site origin"
    end
    def to_s = value
  end
end
