class MenuLocation < ApplicationRecord
  belongs_to :site
  belongs_to :draft_menu, class_name: "Menu", optional: true
  belongs_to :published_menu, class_name: "Menu", optional: true
  before_save { Navigation::Mutation.require_managed! }
  before_destroy { Navigation::Mutation.require_managed! }
end
