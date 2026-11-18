class CreateContentPortability < ActiveRecord::Migration[8.1]
  def change
    add_column :contents, :portable_metadata, :json
    execute "UPDATE contents SET portable_metadata = '{}'"
    change_column_null :contents, :portable_metadata, false
    create_table :portability_states do |t|
      t.references :site, null: false, foreign_key: true, index: { unique: true }
      t.string :public_id, null: false, limit: 36
      t.bigint :active_import_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps precision: 6
    end
    add_index :portability_states, :public_id, unique: true
    create_table :portability_identities do |t|
      t.references :site, null: false, foreign_key: true
      t.string :kind, null: false, limit: 32
      t.string :record_key, null: false, limit: 120
      t.string :public_id, null: false, limit: 36
      t.timestamps precision: 6
    end
    add_index :portability_identities, [ :site_id, :kind, :record_key ], unique: true, name: "portable_record_identity"
    add_index :portability_identities, :public_id, unique: true
    create_table :portability_exports do |t|
      t.references :site, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :public_id, null: false, limit: 36
      t.bigint :approval_session_id, null: false
      t.integer :auth_version, null: false
      t.string :state, null: false, default: "queued", limit: 32
      t.json :scope, null: false
      t.json :report, null: false
      t.string :archive_sha256, limit: 64
      t.bigint :archive_bytes
      t.string :failure, limit: 200
      t.integer :lock_version, null: false, default: 0
      t.timestamps precision: 6
    end
    add_index :portability_exports, :public_id, unique: true
    create_table :import_batches do |t|
      t.references :site, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :public_id, null: false, limit: 36
      t.string :idempotency_key, null: false, limit: 64
      t.bigint :approval_session_id, null: false
      t.integer :auth_version, null: false
      t.string :state, null: false, default: "queued", limit: 32
      t.string :archive_sha256, null: false, limit: 64
      t.bigint :archive_bytes, null: false
      t.integer :format_version
      t.string :normalized_sha256, limit: 64
      t.json :manifest, null: false
      t.json :report, null: false
      t.json :decisions, null: false
      t.json :lease, null: false
      t.string :lease_token, limit: 32
      t.string :baseline_sha256, limit: 64
      t.integer :progress, null: false, default: 0
      t.integer :total, null: false, default: 0
      t.string :failure, limit: 200
      t.integer :lock_version, null: false, default: 0
      t.timestamps precision: 6
    end
    add_index :import_batches, :public_id, unique: true
    add_index :import_batches, [ :site_id, :idempotency_key ], unique: true
    add_foreign_key :portability_states, :import_batches, column: :active_import_id
    create_table :import_items do |t|
      t.references :import_batch, null: false, foreign_key: true
      t.string :source_ref, null: false, limit: 80
      t.string :kind, null: false, limit: 32
      t.string :state, null: false, default: "planned", limit: 32
      t.bigint :target_id
      t.boolean :created_record, null: false, default: false
      t.string :source_sha256, null: false, limit: 64
      t.string :target_sha256, limit: 64
      t.json :details, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps precision: 6
    end
    add_index :import_items, [ :import_batch_id, :source_ref ], unique: true
    add_index :import_items, [ :kind, :target_id ]
    create_table :import_events do |t|
      t.references :import_batch, null: false, foreign_key: true
      t.bigint :number, null: false
      t.string :event, null: false, limit: 64
      t.json :details, null: false
      t.timestamps precision: 6
    end
    add_index :import_events, [ :import_batch_id, :number ], unique: true
    add_check_constraint :import_batches, "progress >= 0 AND total >= 0 AND archive_bytes > 0", name: "import_nonnegative_progress"
  end
end
