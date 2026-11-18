# frozen_string_literal: true

class Content < ApplicationRecord
  attribute :portable_metadata, default: -> { {} }
  STATES = %w[draft pending scheduled published trashed].freeze
  SNAPSHOT_FIELDS = %w[type title slug body excerpt author_id visibility template_key meta_title meta_description featured_blob_id featured_media_id blocks media_details home_page portable_metadata].freeze
  has_many :media_references
  belongs_to :featured_media, class_name: "MediaAsset", optional: true
  belongs_to :author, class_name: "User"
  belongs_to :featured_blob, class_name: "ActiveStorage::Blob", optional: true
  has_many :content_terms
  has_many :content_revisions
  has_many :content_previews
  before_validation :normalize_content
  validate :seo_route_available
  before_save :seo_content_change
  before_destroy { Seo::Invalidation.bump! }
  after_save { Seo::Redirects.published!(self) if saved_change_to_published_snapshot? }
  after_commit { Seo::Invalidation.after_commit! }
  before_update :managed_update_only
  validates :title, presence: true, length: { maximum: 200 }
  validates :slug, presence: true, length: { maximum: 160 }
  validates :slug, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*(?:\/[a-z0-9]+(?:-[a-z0-9]+)*){0,2}\z/ }, if: -> { is_a?(Page) }
  validates :slug, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }, unless: -> { is_a?(Page) }
  validates :body, length: { maximum: 200_000 }
  validates :excerpt, length: { maximum: 1000 }
  validates :status, inclusion: { in: STATES }
  validates :visibility, inclusion: { in: %w[public private] }
  validates :template_key, inclusion: { in: %w[standard wide] }
  validates :meta_title, length: { maximum: 160 }
  validates :meta_description, length: { maximum: 320 }
  validate :safe_reserved_slug
  validate :published_slug_stays_stable
  validate :valid_home_kind
  validate do
    Portability::Format.metadata!(portable_metadata)
  rescue Railpress::SiteArchive::Invalid => error
    errors.add(:portable_metadata, error.message)
  end
  scope :publicly_visible, -> { where(status: "published", published_visibility: "public").where.not(published_at: nil).where.not(published_snapshot: nil) }
  # Compatibility entry point: time is metadata, never a second publication authority.
  scope :publicly_visible_at, ->(_at) { publicly_visible }

  def publicly_visible?
    status == "published" && published_visibility == "public" && published_at.present? && published_snapshot.present?
  end

  def managed_change
    @managed_change = true
    yield
  ensure
    @managed_change = false
  end
  def draft_terms
    Term.joins(:content_terms).where(content_terms: { content_id: id, stage: "draft" }).order(:id).lock
  end
  def snapshot
    attributes.slice(*SNAPSHOT_FIELDS).merge("term_ids" => draft_terms.pluck(:id))
  end
  private
  def seo_route_available
    return if slug.blank?
    path = Railpress::ContentRoutes.path(type, Railpress::ContentRoutes.content_slug(type, slug))
    claim = Redirect.find_by(source_digest: Digest::SHA256.hexdigest(path))
    errors.add(:slug, "belongs to a retained historical URL") if claim && (id.nil? || claim.target_content_id != id)
  end
  def seo_content_change
    Seo::Invalidation.bump! if will_save_change_to_published_snapshot? || will_save_change_to_published_at? || will_save_change_to_published_visibility?
  end
  def normalize_content
    self.slug = Railpress::ContentRoutes.content_slug(type, slug.presence || title)
    self.slug_key = Railpress::ContentRoutes.content_key(type, slug)
    self.body = Editorial::RichText.clean(body.to_s)
  end
  def managed_update_only
    return if @managed_change
    errors.add(:base, "Use the editorial workflow")
    throw :abort
  end
  def safe_reserved_slug
    errors.add(:slug, "is reserved by core routes") if Railpress::ContentRoutes.reserved_content_slug?(type, slug)
  end
  def published_slug_stays_stable
    if status == "published" && published_snapshot && slug != published_snapshot["slug"]
      errors.add(:slug, "can change after unpublishing; live URLs stay stable while editing")
    end
  end
  def valid_home_kind
    errors.add(:home_page, "is available only for Pages") if home_page && type != "Page"
  end
end
