# frozen_string_literal: true

require "uri"

class Site < ApplicationRecord
  attribute :privacy_first_anonymous, :boolean, default: true
  validates :privacy_first_anonymous, inclusion: { in: [ true, false ] }
  validates :privacy_revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  before_update do
    self.privacy_revision += 1 if will_save_change_to_privacy_first_anonymous? && !will_save_change_to_privacy_revision?
  end
  belongs_to :owner, class_name: "User"
  validates :membership_mode, inclusion: { in: %w[disabled email discord both] }
  validates :membership_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :singleton_key, inclusion: { in: [ 1 ] }
  validates :install_id, format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/ }
  validates :title, presence: true, length: { maximum: 120 }
  validates :tagline, length: { maximum: 240 }
  validates :locale, inclusion: { in: [ "en" ] }
  validates :home_mode, inclusion: { in: %w[static blog] }
  validates :canonical_origin, length: { maximum: 255 }
  validate :valid_origin
  validate :valid_timezone
  validate :owner_has_owner_role
  before_validation :normalize_origin
  validates :organization_name, length: { maximum: 200 }
  before_update do
    fields = %w[title tagline canonical_origin locale indexing_enabled home_mode homepage_content_id organization_name]
    if fields.any? { |field| will_save_change_to_attribute?(field) }
      self.seo_generation += 1
      self.seo_changed_at = Time.current
    end
  end
  after_commit { Seo::Invalidation.after_commit! }

  private
  def normalize_origin
    self.canonical_origin = canonical_origin.to_s.strip.delete_suffix("/")
    self.canonical_origin = Seo::SiteOrigin.new(canonical_origin).to_s
  rescue Seo::SiteOrigin::Invalid
    nil
  end
  def valid_origin
    Seo::SiteOrigin.new(canonical_origin)
  rescue Seo::SiteOrigin::Invalid
    errors.add(:canonical_origin, "must be an HTTPS origin without credentials, path, query or fragment")
  end
  def valid_timezone
    TZInfo::Timezone.get(timezone.to_s)
  rescue TZInfo::InvalidTimezoneIdentifier
    errors.add(:timezone, "must be an IANA timezone")
  end
  def owner_has_owner_role
    errors.add(:owner, "must have the owner role") unless owner&.owner?
  end
end
