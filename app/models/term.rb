class Term < ApplicationRecord
  before_save { Seo::Invalidation.bump! }
  before_destroy { Seo::Invalidation.bump! }
  after_commit { Seo::Invalidation.after_commit! }
  belongs_to :taxonomy
  has_many :content_terms
  before_validation do
    self.slug = Railpress::ContentRoutes.slug(slug.presence || name)
    self.slug_key = Railpress::ContentRoutes.key(slug)
  end
  validates :name, presence: true, length: { maximum: 100 }
  validates :slug, presence: true, length: { maximum: 160 }, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
end
