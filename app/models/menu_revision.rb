class MenuRevision < ApplicationRecord
  belongs_to :menu
  belongs_to :actor, class_name: "User"
  before_create { Navigation::Mutation.require_managed! }
  before_update { raise ActiveRecord::ReadOnlyRecord, "Menu revisions are immutable" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "Menu revisions are immutable" }
end
