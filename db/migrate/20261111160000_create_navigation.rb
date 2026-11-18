class CreateNavigation < ActiveRecord::Migration[8.1]
  def change
    create_table :navigation_states do |t|
      t.references :site, null: false, foreign_key: true, index: { unique: true }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :navigation_states, "lock_version >= 0", name: "navigation_version"
    create_table :menus do |t|
      t.references :site, null: false, foreign_key: true
      t.string :name, null: false, limit: 100
      t.string :status, null: false, default: "active", limit: 16
      t.integer :lock_version, null: false, default: 0
      t.bigint :published_revision_id
      t.timestamps
    end
    add_index :menus, [ :site_id, :id ], unique: true
    add_check_constraint :menus, "lock_version >= 0 AND status IN ('active','deleted')", name: "menu_state"
    create_table :menu_revisions do |t|
      t.references :menu, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.integer :state_version, null: false
      t.string :operation, null: false, limit: 24
      t.json :snapshot, null: false
      t.json :before_snapshot, null: false
      t.datetime :created_at, null: false
    end
    add_index :menu_revisions, [ :menu_id, :number ], unique: true
    add_index :menu_revisions, [ :menu_id, :id ], unique: true
    add_check_constraint :menu_revisions, "number > 0 AND state_version > 0", name: "menu_revision_number"
    add_foreign_key :menus, :menu_revisions, column: [ :id, :published_revision_id ], primary_key: [ :menu_id, :id ], name: "menu_own_publication"
    create_table :menu_items do |t|
      t.references :menu, null: false, foreign_key: true
      t.string :key, null: false, limit: 32
      t.string :parent_key, limit: 32
      t.string :parent_scope, null: false, limit: 32
      t.integer :position, null: false
      t.string :label, null: false, limit: 120
      t.string :kind, null: false, limit: 16
      t.references :content, foreign_key: true
      t.references :term, foreign_key: true
      t.string :url, limit: 2048
    end
    add_index :menu_items, [ :menu_id, :key ], unique: true
    add_index :menu_items, [ :menu_id, :parent_scope, :position ], unique: true, name: "menu_sibling_order"
    add_foreign_key :menu_items, :menu_items, column: [ :menu_id, :parent_key ], primary_key: [ :menu_id, :key ], name: "menu_own_parent"
    add_check_constraint :menu_items, "position >= 0 AND position < 30", name: "menu_position"
    add_check_constraint :menu_items, "(parent_key IS NULL AND parent_scope = 'root') OR (parent_key IS NOT NULL AND parent_scope = parent_key AND parent_key <> #{connection.quote_column_name(:key)})", name: "menu_parent_scope"
    add_check_constraint :menu_items, "(kind IN ('Page','Post') AND content_id IS NOT NULL AND term_id IS NULL AND url IS NULL) OR (kind = 'Term' AND content_id IS NULL AND term_id IS NOT NULL AND url IS NULL) OR (kind = 'Custom' AND content_id IS NULL AND term_id IS NULL AND url IS NOT NULL)", name: "menu_typed_target"
    create_table :menu_locations do |t|
      t.references :site, null: false, foreign_key: true
      t.string :theme_key, null: false, limit: 40
      t.string :key, null: false, limit: 32
      t.bigint :draft_menu_id
      t.bigint :published_menu_id
    end
    add_index :menu_locations, [ :site_id, :theme_key, :key ], unique: true, name: "menu_location_identity"
    add_foreign_key :menu_locations, :menus, column: [ :site_id, :draft_menu_id ], primary_key: [ :site_id, :id ], name: "menu_draft_site"
    add_foreign_key :menu_locations, :menus, column: [ :site_id, :published_menu_id ], primary_key: [ :site_id, :id ], name: "menu_live_site"
  end
end
