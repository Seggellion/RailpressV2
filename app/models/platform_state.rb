# frozen_string_literal: true

require "digest"

# Portable internal state primitive; never stores credentials or published content.
class PlatformState < ApplicationRecord
  before_validation :normalize_identity
  validates :scope_name, :key_name, presence: true, length: { maximum: 255 }

  def self.normalized(value)
    value.to_s.unicode_normalize(:nfc).downcase(:fold).unicode_normalize(:nfc)
  end

  private

  def normalize_identity
    self.scope_name = self.class.normalized(scope_name)
    self.key_name = self.class.normalized(key_name)
    self.scope_digest = Digest::SHA256.hexdigest(scope_name)
    self.key_digest = Digest::SHA256.hexdigest(key_name)
  end
end
