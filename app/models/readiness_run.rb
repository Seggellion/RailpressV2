class ReadinessRun < ApplicationRecord
  attribute :findings, :json, default: -> { [] }
  attribute :fingerprint, :json, default: -> { {} }
  attribute :timing, :json, default: -> { {} }
  belongs_to :site
  belongs_to :actor, class_name: "User", optional: true
  validates :state, inclusion: { in: %w[pending running complete failed cancelled] }
  validates :findings, length: { maximum: 32 }
end
