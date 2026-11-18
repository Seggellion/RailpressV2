class PortabilityIdentity < ApplicationRecord
  belongs_to :site
  before_validation { self.public_id ||= SecureRandom.uuid }
  validates :kind, inclusion: { in: %w[content revision term media menu menu_node author] }
  validates :record_key, presence: true, length: { maximum: 120 }
  validates :public_id, format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/ }
end
