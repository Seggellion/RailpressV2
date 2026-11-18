class ContentPreview < ApplicationRecord
  include SecurityDeadline
  LIFETIME = 10.minutes
  has_many :media_references, dependent: :delete_all
  belongs_to :content
  belongs_to :actor, class_name: "User"
end
