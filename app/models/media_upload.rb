class MediaUpload < ApplicationRecord
  belongs_to :author, class_name: "User"
  validates :state, inclusion: { in: %w[processing accepted rejected] }
end
