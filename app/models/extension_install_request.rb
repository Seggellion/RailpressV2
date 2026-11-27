# frozen_string_literal: true

class ExtensionInstallRequest < ApplicationRecord
  belongs_to :site

  IDENTITY_FIELDS = %w[site_id actor_id actor_auth_version site_identity site_origin request_key operation module_id version package_sha256 manifest_sha256 plan_sha256 core_version engine_generation engine_fingerprint activation_generation].freeze
  OPERATIONS = %w[install upgrade revert uninstall].freeze
  PENDING = %w[awaiting_operator verifying migrating restarting held recovery_required].freeze
  TERMINAL = %w[installed retained failed cancelled].freeze

  validates :request_key, format: { with: Railpress::Releases::UUID }
  validates :operation, inclusion: { in: OPERATIONS }
  validates :state, inclusion: { in: PENDING + TERMINAL }

  before_update do
    if IDENTITY_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
      raise ActiveRecord::ReadOnlyRecord, "Extension request identity is immutable"
    end
  end
end
