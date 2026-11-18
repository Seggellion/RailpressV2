class ImportBatch < ApplicationRecord
  %w[manifest report decisions lease].each { |name| attribute name, default: -> { {} } }
  STATES = %w[receiving queued inspecting review staging staged activating complete reversing reversed blocked needs_approval failed].freeze
  belongs_to :site
  belongs_to :actor, class_name: "User"
  has_many :import_items
  has_many :import_events
  before_validation { self.public_id ||= SecureRandom.uuid }
  validates :state, inclusion: { in: STATES }
  validates :archive_sha256, :idempotency_key, format: { with: /\A[0-9a-f]{64}\z/ }
  def self.event!(batch, name, details = {})
    number = (batch.import_events.order(number: :desc).lock.first&.number || 0) + 1
    batch.import_events.create!(number: number, event: name, details: details)
  end
end
