class CreateThemeApi < ActiveRecord::Migration[8.1]
  def change
    create_table :theme_installations do |t|
      t.references :site, null: false, foreign_key: true
      t.string :theme_key, null: false, limit: 40
      t.string :version, null: false, limit: 80
      t.string :digest, null: false, limit: 64
      t.string :status, null: false, default: "validated", limit: 16
      t.json :manifest, null: false
      t.json :smoke_report, null: false
      t.datetime :ever_active_at
      t.timestamps
    end
    add_index :theme_installations, [ :site_id, :theme_key, :version, :digest ], unique: true, name: "theme_package_identity"
    add_check_constraint :theme_installations, "status IN ('validated','removed')", name: "theme_install_status"
    create_table :theme_overlays do |t|
      t.references :theme_installation, null: false, foreign_key: true
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.json :options, null: false
      t.json :media_details, null: false
      t.datetime :created_at, null: false
    end
    add_index :theme_overlays, [ :theme_installation_id, :number ], unique: true, name: "theme_overlay_version"
    add_check_constraint :theme_overlays, "number > 0", name: "theme_overlay_positive"
    create_table :theme_states do |t|
      t.references :site, null: false, foreign_key: true, index: { unique: true }
      t.string :default_key, null: false, default: "dusk", limit: 40
      t.references :active_installation, foreign_key: { to_table: :theme_installations }
      t.references :previous_installation, foreign_key: { to_table: :theme_installations }
      t.references :active_overlay, foreign_key: { to_table: :theme_overlays }
      t.references :previous_overlay, foreign_key: { to_table: :theme_overlays }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :theme_states, "default_key = 'dusk' AND lock_version >= 0", name: "theme_default_and_version"
    add_check_constraint :theme_states, "(active_installation_id IS NULL AND active_overlay_id IS NULL) OR (active_installation_id IS NOT NULL AND active_overlay_id IS NOT NULL)", name: "theme_active_pair"
    create_table :theme_previews do |t|
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.references :theme_installation, null: false, foreign_key: true
      t.references :theme_overlay, null: false, foreign_key: true
      t.string :token_digest, null: false, limit: 64
      t.string :session_digest, null: false, limit: 64
      t.integer :auth_version, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :theme_previews, :token_digest, unique: true
    add_reference :media_references, :theme_overlay, foreign_key: true
    remove_check_constraint :media_references, name: "media_reference_owner"
    add_check_constraint :media_references, "(theme_overlay_id IS NULL AND content_id IS NOT NULL AND content_revision_id IS NULL AND content_preview_id IS NULL AND stage IN ('draft','live')) OR (theme_overlay_id IS NULL AND content_id IS NULL AND content_revision_id IS NOT NULL AND content_preview_id IS NULL AND stage = 'revision') OR (theme_overlay_id IS NULL AND content_id IS NULL AND content_revision_id IS NULL AND content_preview_id IS NOT NULL AND stage = 'preview') OR (theme_overlay_id IS NOT NULL AND content_id IS NULL AND content_revision_id IS NULL AND content_preview_id IS NULL AND stage = 'theme')", name: "media_reference_owner"
    add_index :media_references, [ :theme_overlay_id, :media_asset_id ], unique: true, name: "media_theme_overlay"
  end
end
