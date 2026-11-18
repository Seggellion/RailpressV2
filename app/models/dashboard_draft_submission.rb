class DashboardDraftSubmission < ApplicationRecord
  belongs_to :site
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :content
end
