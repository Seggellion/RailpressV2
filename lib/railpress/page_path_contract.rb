# Additive reader capability, also declared by this file's signed bundle entry.
module Railpress
  module PagePathContract
    VERSION = 1
    MAX_DEPTH = 3
    module_function
    def normalize(value)
      parts = value.to_s.split("/", -1)
      return "" unless parts.length.between?(1, MAX_DEPTH) && parts.none? { |part| part.blank? || %w[. ..].include?(part) || part.match?(/[\\%?#\x00-\x1f]/) }
      normalized = parts.map { |part| yield part }
      normalized.any?(&:empty?) ? "" : normalized.join("/")
    end
  end
end
