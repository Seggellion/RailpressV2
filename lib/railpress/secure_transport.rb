# frozen_string_literal: true

require "ipaddr"

module Railpress
  module SecureTransport
    module_function

    def secure?(env)
      %w[https on 1].include?(env["HTTPS"].to_s.downcase) ||
        (trusted_proxy?(env) && env["HTTP_X_FORWARDED_PROTO"] == "https")
    end

    def trusted_proxy?(env)
      peer = env["REMOTE_ADDR"].to_s
      ENV.fetch("RAILPRESS_TLS_PROXY_IPS", "").split(",").any? { |entry| IPAddr.new(entry.strip).include?(peer) }
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
