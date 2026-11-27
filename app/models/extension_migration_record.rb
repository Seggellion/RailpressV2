# frozen_string_literal: true

class ExtensionMigrationRecord < ApplicationRecord
  belongs_to :site

  validates :state, inclusion: { in: %w[started applied recovery_required] }
end
