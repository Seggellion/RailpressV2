class MediaAsset < ApplicationRecord
  METADATA = %w[title alt_text decorative caption attribution license_notes].freeze
  belongs_to :author, class_name: "User"
  belongs_to :blob, class_name: "ActiveStorage::Blob", optional: true
  belongs_to :thumbnail_blob, class_name: "ActiveStorage::Blob", optional: true
  has_many :media_references
  validates :blob, :thumbnail_blob, presence: true, if: -> { state == "ready" }
  validates :sha256, :source_sha256, :thumbnail_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :title, presence: true, length: { maximum: 200 }
  validates :alt_text, length: { maximum: 500 }
  validates :caption, length: { maximum: 2000 }
  validates :attribution, :license_notes, length: { maximum: 1000 }
  validates :alt_text, presence: true, unless: :decorative?
  validates :state, inclusion: { in: %w[ready purging purged] }
  scope :ready, -> { where(state: "ready") }
  before_update do
    throw :abort unless @managed_change
  end
  def managed_change
    @managed_change = true
    yield
  ensure
    @managed_change = false
  end
  def accessibility_snapshot
    attributes.slice("public_id", *METADATA, "width", "height", "sha256")
  end
end
