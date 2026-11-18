require "uri"
module Navigation
  module SafeUrl
    module_function
    def validate!(value)
      raise Mutation::Invalid, "Use a local path or an HTTPS link without credentials." unless value.is_a?(String) && value.valid_encoding? && value.ascii_only? && value.length.between?(1, 2048) &&
        !value.match?(/[\\\x00-\x20\x7f]/) && !value.match?(/%(?:0[0-9a-f]|1[0-9a-f]|20|2f|5c|7f|25)/i)
      uri = URI.parse(value)
      if value.start_with?("/") && !value.start_with?("//")
        raise Mutation::Invalid, "Invalid local link." if uri.host || uri.scheme || value.start_with?("/.")
      else
        raise Mutation::Invalid, "Use HTTPS without credentials." unless uri.is_a?(URI::HTTPS) && uri.host&.match?(/\A[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?\z/i) && !uri.userinfo && uri.port.between?(1, 65535)
      end
      value
    rescue URI::InvalidURIError
      raise Mutation::Invalid, "Invalid link."
    end
  end
end
