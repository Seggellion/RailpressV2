class CreateReleaseControl < ActiveRecord::Migration[8.1]
  def change
    create_table :release_requests do |t|
      t.references :site, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :request_key, null: false, limit: 36
      t.string :release_digest, null: false, limit: 64
      t.string :operation, null: false, limit: 16
      t.integer :actor_auth_version, null: false
      t.json :receipt
      t.integer :receipt_revision, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :release_requests, :request_key, unique: true
  end
end
