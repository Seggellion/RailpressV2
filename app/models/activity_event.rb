class ActivityEvent < ApplicationRecord
  attribute :details, :json, default: -> { {} }
  belongs_to :site
  belongs_to :actor, class_name: "User", optional: true
  before_update { raise ActiveRecord::ReadOnlyRecord, "Activity records are immutable" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "Activity retention is managed separately" }
  validates :actor_name, length: { maximum: 40 }, presence: true
  validates :outcome, inclusion: { in: %w[succeeded denied failed unsupported] }
  validates :category, inclusion: { in: %w[editorial media navigation appearance identity security seo operations] }
end
