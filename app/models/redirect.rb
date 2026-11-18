class Redirect < ApplicationRecord
  belongs_to :target_content, class_name: "Content", optional: true
  before_validation { self.source_digest = Digest::SHA256.hexdigest(source_path.to_s) }
  validate { errors.add(:source_path, "must be a core content path") unless Seo::RouteRegistry.redirect_source?(source_path) }
  validates :source_path, length: { maximum: 1024 }
  after_commit { Seo::Invalidation.after_commit! }
end
