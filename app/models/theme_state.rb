class ThemeState < ApplicationRecord
  belongs_to :site
  belongs_to :active_installation, class_name: "ThemeInstallation", optional: true
  belongs_to :previous_installation, class_name: "ThemeInstallation", optional: true
  belongs_to :active_overlay, class_name: "ThemeOverlay", optional: true
  belongs_to :previous_overlay, class_name: "ThemeOverlay", optional: true
end
