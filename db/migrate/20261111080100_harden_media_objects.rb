class HardenMediaObjects < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :media_assets, "(state = 'ready' AND blob_id IS NOT NULL AND thumbnail_blob_id IS NOT NULL) OR state = 'purging' OR (state = 'purged' AND blob_id IS NULL AND thumbnail_blob_id IS NULL)", name: "media_object_state"
    add_check_constraint :media_assets, "lock_version >= 0 AND source_width > 0 AND source_height > 0", name: "media_source_bounds"
    add_index :media_assets, :blob_id, unique: true, name: "media_unique_blob"
    remove_index :media_assets, name: "index_media_assets_on_blob_id"
    add_index :media_assets, :thumbnail_blob_id, unique: true, name: "media_unique_thumbnail"
    remove_index :media_assets, name: "index_media_assets_on_thumbnail_blob_id"
  end
end
