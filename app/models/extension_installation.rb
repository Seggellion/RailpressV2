# frozen_string_literal: true

class ExtensionInstallation < ApplicationRecord
  belongs_to :site

  validates :package_state, inclusion: { in: %w[installed retained] }
end
