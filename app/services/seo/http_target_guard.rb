# frozen_string_literal: true

# Adapted from UltimaCraft a6e17605689442a91e697eae0584a0c2bf84f4bf; MIT (c) 2024-2026 Dustin Hill.
# See THIRD_PARTY_NOTICES.md. Railpress applies stricter scope and resource limits.

require "ipaddr"
require "resolv"
require "set"
require "timeout"
module Seo
  class HttpTargetGuard
    Result = Data.define(:uri, :ip_address)
    class UnsafeTarget < StandardError; end
    BLOCKED_NETWORKS = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ::ffff:0:0/96 64:ff9b::/96 64:ff9b:1::/48 2001::/23 2001:db8::/32 2002::/16 ff00::/8].map { |range| IPAddr.new(range) }.freeze
    def initialize(origin:, allowed_urls:, resolver: ->(host) { Resolv.getaddresses(host) })
      @origin = URI.parse(SiteOrigin.new(origin).to_s)
      @allowed = allowed_urls.to_set.freeze
      @resolver = resolver
    end
    def call(url)
      raise UnsafeTarget, "url_too_long" if url.to_s.bytesize > 2048
      uri = URI.parse(url.to_s)
      raise UnsafeTarget, "unsupported_destination" unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment && uri.port == 443
      raise UnsafeTarget, "unexpected_origin" unless uri.host.casecmp?(@origin.host) && uri.port == @origin.port
      raise UnsafeTarget, "outside_inventory" unless @allowed.include?(url)
      addresses = Timeout.timeout(2) { Array(@resolver.call(uri.hostname)).map(&:to_s).uniq }
      raise UnsafeTarget, "dns_resolution_failed" unless addresses.length.between?(1, 16)
      parsed = addresses.map { |address| IPAddr.new(address) }
      raise UnsafeTarget, "private_address" if parsed.any? { |ip| blocked?(ip) }
      Result.new(uri: uri.freeze, ip_address: parsed.first.to_s.freeze)
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      raise UnsafeTarget, "invalid_destination"
    rescue Resolv::ResolvError, SocketError, Timeout::Error
      raise UnsafeTarget, "dns_resolution_failed"
    end
    private
    def blocked?(ip)
      return true if ip.ipv6? && !IPAddr.new("2000::/3").include?(ip)
      BLOCKED_NETWORKS.any? { |network| network.ipv4? == ip.ipv4? && network.include?(ip) }
    end
  end
end
