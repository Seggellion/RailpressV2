class ReleaseRequest < ApplicationRecord
  belongs_to :site
  belongs_to :actor, class_name: "User"
  validates :request_key, format: { with: Railpress::Releases::UUID }, uniqueness: true
  validates :release_digest, format: { with: Railpress::Releases::SHA }
  validates :operation, inclusion: { in: %w[inspect stage cancel preflight promote revert] }
  before_update do
    raise ActiveRecord::ReadOnlyRecord, "Release request identity is immutable" if
      %w[site_id actor_id request_key release_digest operation actor_auth_version].any? { |field| will_save_change_to_attribute?(field) }
  end
end
