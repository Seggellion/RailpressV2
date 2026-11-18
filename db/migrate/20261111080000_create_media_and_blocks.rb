class CreateMediaAndBlocks < ActiveRecord::Migration[8.1]
  def change
    create_table :media_assets do |t|
      t.string :public_id, null: false, limit: 36
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.references :blob, foreign_key: { to_table: :active_storage_blobs }
      t.references :thumbnail_blob, foreign_key: { to_table: :active_storage_blobs }
      t.string :state, null: false, default: "ready", limit: 16
      t.string :filename, null: false, limit: 160
      t.string :title, null: false, limit: 200
      t.string :content_type, null: false, limit: 32
      t.string :source_sha256, null: false, limit: 64
      t.string :sha256, null: false, limit: 64
      t.string :thumbnail_sha256, null: false, limit: 64
      t.bigint :source_bytes, null: false
      t.bigint :byte_size, null: false
      t.integer :width, null: false
      t.integer :height, null: false
      t.integer :source_width, null: false
      t.integer :source_height, null: false
      t.string :alt_text, null: false, default: "", limit: 500
      t.boolean :decorative, null: false, default: false
      t.text :caption
      t.text :attribution
      t.text :license_notes
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :media_assets, :public_id, unique: true
    add_check_constraint :media_assets, "state IN ('ready','purging','purged')", name: "media_state"
    add_check_constraint :media_assets, "width > 0 AND height > 0 AND byte_size > 0 AND source_bytes > 0", name: "media_dimensions"
    add_check_constraint :media_assets, "content_type = 'image/png'", name: "media_canonical_type"
    create_table :media_uploads do |t|
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.string :state, null: false, default: "processing", limit: 16
      t.string :reason, limit: 32
      t.bigint :byte_size, null: false, default: 0
      t.string :source_sha256, limit: 64
      t.json :storage_keys
      t.timestamps
    end
    add_check_constraint :media_uploads, "state IN ('processing','accepted','rejected')", name: "media_upload_state"
    add_reference :contents, :featured_media, foreign_key: { to_table: :media_assets }
    add_column :contents, :blocks, :json
    add_column :contents, :media_details, :json
    create_table :media_references do |t|
      t.references :media_asset, null: false, foreign_key: true
      t.references :content, foreign_key: true
      t.references :content_revision, foreign_key: true
      t.references :content_preview, foreign_key: true
      t.string :stage, null: false, limit: 16
    end
    add_index :media_references, [ :media_asset_id, :content_id, :stage ], unique: true, name: "media_content_stage"
    add_index :media_references, [ :media_asset_id, :content_revision_id ], unique: true, name: "media_revision"
    add_index :media_references, [ :media_asset_id, :content_preview_id ], unique: true, name: "media_preview"
    add_check_constraint :media_references,
      "(content_id IS NOT NULL AND content_revision_id IS NULL AND content_preview_id IS NULL AND stage IN ('draft','live')) OR (content_id IS NULL AND content_revision_id IS NOT NULL AND content_preview_id IS NULL AND stage = 'revision') OR (content_id IS NULL AND content_revision_id IS NULL AND content_preview_id IS NOT NULL AND stage = 'preview')",
      name: "media_reference_owner"
  end
end
