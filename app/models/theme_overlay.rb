class ThemeOverlay < ApplicationRecord
  belongs_to :theme_installation
  belongs_to :author, class_name: "User"
  has_many :media_references
  before_update { throw :abort }
end
