class ThemePreview < ApplicationRecord
  include SecurityDeadline
  LIFETIME = 10.minutes
  belongs_to :actor, class_name: "User"
  belongs_to :theme_installation
  belongs_to :theme_overlay
end
