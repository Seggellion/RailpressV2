class NavigationPreview < ApplicationRecord
  include SecurityDeadline
  LIFETIME = 10.minutes
  belongs_to :actor, class_name: "User"
  belongs_to :menu
end
