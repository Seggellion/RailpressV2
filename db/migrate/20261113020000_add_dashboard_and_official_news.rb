class AddDashboardAndOfficialNews < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboard_draft_submissions do |t|
      t.references :site, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :content, null: false, foreign_key: true
      t.string :request_key, limit: 36, null: false
      t.string :request_digest, limit: 64, null: false
      t.timestamps
    end
    add_index :dashboard_draft_submissions, [ :site_id, :request_key ], unique: true, name: "dashboard_submission_identity"
    create_table :official_news_states do |t|
      t.references :site, null: false, foreign_key: true, index: { unique: true }
      t.boolean :enabled, null: false, default: false
      t.boolean :provider_enabled, null: false, default: false
      t.integer :generation, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.json :payload
      t.string :etag, limit: 200
      t.string :last_modified, limit: 100
      t.datetime :retrieved_at, precision: 6
      t.json :fresh_binding
      t.json :retention_binding
      t.json :wait_binding
      t.json :lease_binding
      t.string :lease_key, limit: 36
      t.integer :failures, null: false, default: 0
      t.string :last_error, limit: 64
      t.timestamps
    end
    add_check_constraint :official_news_states, "generation >= 0 AND lock_version >= 0 AND failures >= 0 AND failures <= 16", name: "official_news_bounds"
    create_table :official_news_reviews do |t|
      t.references :content, null: false, foreign_key: true, index: { unique: true }
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :publication_revision, null: false, foreign_key: { to_table: :content_revisions }
      t.string :public_id, limit: 36, null: false
      t.string :publication_digest, limit: 64, null: false
      t.timestamps
    end
    add_index :official_news_reviews, :public_id, unique: true
  end
end
