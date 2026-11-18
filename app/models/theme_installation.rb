class ThemeInstallation < ApplicationRecord
  belongs_to :site
  has_many :theme_overlays, dependent: :restrict_with_error
  validates :status, inclusion: { in: %w[validated removed] }
  def public_identity = "#{theme_key}@#{version}:#{digest}"
end
