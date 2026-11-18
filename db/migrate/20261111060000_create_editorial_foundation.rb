class CreateEditorialFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :contents do |t|
      t.string :type, null: false, limit: 16
      t.string :title, null: false, limit: 200
      t.string :slug, null: false, limit: 160
      t.string :slug_key, null: false, limit: 64
      t.text :body, null: false
      t.text :excerpt
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "draft", limit: 16
      t.string :visibility, null: false, default: "public", limit: 16
      t.string :template_key, null: false, default: "standard", limit: 32
      t.string :meta_title, limit: 160
      t.string :meta_description, limit: 320
      t.references :featured_blob, foreign_key: { to_table: :active_storage_blobs }
      t.string :published_visibility, limit: 16
      t.boolean :pending_review, null: false, default: false
      t.references :scheduled_by, foreign_key: { to_table: :users }
      t.datetime :scheduled_at
      t.datetime :published_at
      t.datetime :first_published_at
      t.json :published_snapshot
      t.boolean :home_page, null: false, default: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_reference :sites, :homepage_content, foreign_key: { to_table: :contents }
    add_index :contents, [ :type, :slug_key ], unique: true
    add_index :contents, [ :status, :scheduled_at ]
    add_check_constraint :contents, "type IN ('Page','Post')", name: "content_type"
    add_check_constraint :contents, "status IN ('draft','pending','scheduled','published','trashed')", name: "content_status"
    add_check_constraint :contents, "visibility IN ('public','private')", name: "content_visibility"
    add_check_constraint :contents, "template_key IN ('standard','wide')", name: "content_template"
    add_check_constraint :contents, "lock_version >= 0", name: "content_version"
    create_table :taxonomies do |t|
      t.string :kind, null: false, limit: 16
      t.timestamps
    end
    add_index :taxonomies, :kind, unique: true
    add_check_constraint :taxonomies, "kind IN ('category','tag')", name: "taxonomy_kind"
    create_table :terms do |t|
      t.references :taxonomy, null: false, foreign_key: true
      t.string :name, null: false, limit: 100
      t.string :slug, null: false, limit: 160
      t.string :slug_key, null: false, limit: 64
      t.timestamps
    end
    add_index :terms, [ :taxonomy_id, :slug_key ], unique: true
    create_table :content_terms do |t|
      t.references :content, null: false, foreign_key: true
      t.references :term, null: false, foreign_key: true
      t.string :stage, null: false, limit: 8
    end
    add_index :content_terms, [ :content_id, :term_id, :stage ], unique: true
    add_check_constraint :content_terms, "stage IN ('draft','live')", name: "content_term_stage"
    create_table :content_revisions do |t|
      t.references :content, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.string :event, null: false, limit: 32
      t.json :snapshot, null: false
      t.datetime :created_at, null: false
    end
    add_index :content_revisions, [ :content_id, :number ], unique: true
    create_table :content_previews do |t|
      t.references :content, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :token_digest, null: false, limit: 64
      t.integer :auth_version, null: false
      t.json :snapshot, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :content_previews, :token_digest, unique: true
  end
end
