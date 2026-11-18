class Menu < ApplicationRecord
  belongs_to :site
  belongs_to :published_revision, class_name: "MenuRevision", optional: true
  has_many :navigation_previews, dependent: :delete_all
  has_many :menu_items
  has_many :menu_revisions
  before_save { Navigation::Mutation.require_managed! }
  before_destroy { Navigation::Mutation.require_managed! }
  validates :name, presence: true, length: { maximum: 100 }
  def tree
    rows = menu_items.order(:position, :key)
    rows = rows.lock if ActiveSupport::IsolatedExecutionState[:navigation_mutation]
    rows.map { |item| item.attributes.slice(*Navigation::Tree::FIELDS) }
  end
end
