class ContentRevision < ApplicationRecord
  belongs_to :content
  belongs_to :actor, class_name: "User", optional: true
  before_update { throw :abort }
  before_destroy { throw :abort }
end
