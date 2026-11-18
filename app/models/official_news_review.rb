class OfficialNewsReview < ApplicationRecord
  belongs_to :content
  belongs_to :actor, class_name: "User", optional: true
end
