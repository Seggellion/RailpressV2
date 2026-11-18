class MenuItem < ApplicationRecord
  belongs_to :menu
  belongs_to :content, optional: true
  belongs_to :term, optional: true
  before_save { Navigation::Mutation.require_managed! }
  before_destroy { Navigation::Mutation.require_managed! }
end
