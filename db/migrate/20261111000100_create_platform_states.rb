class CreatePlatformStates < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_states do |t|
      t.string :scope_name, null: false
      t.string :key_name, null: false
      t.string :scope_digest, limit: 64, null: false
      t.string :key_digest, limit: 64, null: false
      t.json :payload, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :platform_states, [ :scope_digest, :key_digest ], unique: true, name: "index_platform_states_identity"
    add_check_constraint :platform_states, "lock_version >= 0", name: "platform_states_lock_version_nonnegative"
  end
end
