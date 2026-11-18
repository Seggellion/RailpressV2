class PortabilityExport < ApplicationRecord
  %w[scope report].each { |name| attribute name, default: -> { {} } }
  belongs_to :site
  belongs_to :actor, class_name: "User"
  before_validation { self.public_id ||= SecureRandom.uuid }
  validates :state, inclusion: { in: %w[queued working ready blocked failed] }
end
