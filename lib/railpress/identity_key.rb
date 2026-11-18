# frozen_string_literal: true

require "digest"

module Railpress
  module IdentityKey
    module_function
    def normalize(value)
      value.to_s.strip.unicode_normalize(:nfc).downcase(:fold).unicode_normalize(:nfc)
    end
    def digest(value)
      Digest::SHA256.hexdigest(normalize(value))
    end
  end
end
