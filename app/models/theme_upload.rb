# frozen_string_literal: true

class ThemeUpload < ApplicationRecord
  STATES = %w[queued validating staging staged rejected held].freeze
  RESUMABLE = %w[queued validating staging held].freeze
  belongs_to :site
  belongs_to :theme_installation, optional: true
  validates :state, inclusion: { in: STATES }
  validates :operation_key, format: { with: Railpress::Releases::UUID }
  validates :transport_sha256, format: { with: Railpress::Releases::SHA }
end
