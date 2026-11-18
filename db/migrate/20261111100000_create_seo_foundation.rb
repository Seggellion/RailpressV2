class CreateSeoFoundation < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :seo_generation, :bigint, null: false, default: 0
    add_column :sites, :seo_changed_at, :datetime
    add_column :sites, :organization_name, :string, limit: 200
    add_check_constraint :sites, "seo_generation >= 0", name: "seo_generation_nonnegative"
    add_column :contents, :public_updated_at, :datetime
    add_column :contents, :public_search_text, :text
    add_column :contents, :last_public_path, :string, limit: 1024
    reversible do |dir|
      dir.up do
        rows = Class.new(ActiveRecord::Base) { self.table_name = "contents"; self.inheritance_column = :_unused_type }
        rows.reset_column_information
        site = connection.select_one("SELECT home_mode, homepage_content_id FROM sites WHERE singleton_key = 1")
        rows.where.not(published_snapshot: nil).select(:id, :type, :published_snapshot, :published_at).find_each(batch_size: 25) do |row|
          data = row.published_snapshot
          path = row.type == "Post" ? "/blog/#{data.fetch('slug')}" : "/#{data.fetch('slug')}"
          path = "/" if row.type == "Page" && site && site["home_mode"] == "static" && site["homepage_content_id"].to_i == row.id
          row.update_columns(public_updated_at: row.published_at, last_public_path: path, public_search_text: [ data["title"], data["excerpt"] ].join(" "))
        end
      end
    end
    create_table :redirects do |t|
      t.text :source_path, null: false
      t.string :source_digest, null: false, limit: 64
      t.references :target_content, foreign_key: { to_table: :contents, on_delete: :nullify }
      t.timestamps
    end
    add_index :redirects, :source_digest, unique: true
    create_table :seo_diagnostic_runs do |t|
      t.references :requester, null: false, foreign_key: { to_table: :users }
      t.string :active_key, limit: 32
      t.string :status, null: false, default: "pending", limit: 16
      t.string :mode, null: false, limit: 16
      t.string :origin, null: false, limit: 255
      t.bigint :generation, null: false
      t.json :summary, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :seo_diagnostic_runs, :active_key, unique: true
    add_check_constraint :seo_diagnostic_runs, "mode IN ('offline','http')", name: "seo_run_mode"
    add_check_constraint :seo_diagnostic_runs, "(status IN ('pending','running') AND active_key IS NOT NULL AND active_key = 'site' AND finished_at IS NULL) OR (status IN ('completed','failed','cancelled') AND active_key IS NULL AND finished_at IS NOT NULL)", name: "seo_run_lifecycle"
    add_check_constraint :seo_diagnostic_runs, "generation >= 0", name: "seo_run_generation"
    create_table :seo_diagnostic_targets do |t|
      t.references :seo_diagnostic_run, null: false, foreign_key: true
      t.text :url, null: false
      t.string :url_digest, null: false, limit: 64
      t.string :family, null: false, limit: 24
      t.integer :position, null: false
      t.json :result, null: false
      t.datetime :checked_at
    end
    add_index :seo_diagnostic_targets, [ :seo_diagnostic_run_id, :url_digest ], unique: true, name: "seo_target_digest"
    add_index :seo_diagnostic_targets, [ :seo_diagnostic_run_id, :position ], unique: true, name: "seo_target_position"
    add_check_constraint :seo_diagnostic_targets, "position >= 0", name: "seo_target_position_nonnegative"
  end
end
