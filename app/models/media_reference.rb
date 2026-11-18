class MediaReference < ApplicationRecord
  belongs_to :theme_overlay, optional: true
  belongs_to :media_asset
  belongs_to :content, optional: true
  belongs_to :content_revision, optional: true
  belongs_to :content_preview, optional: true
end
