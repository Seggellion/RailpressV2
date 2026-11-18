class CreateIdentityFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :username, limit: 40, null: false
      t.string :email, limit: 254, null: false
      t.string :username_key, limit: 64, null: false
      t.string :email_key, limit: 64, null: false
      t.string :password_digest, null: false
      t.string :role, limit: 16, null: false
      t.integer :auth_version, null: false, default: 0
      t.timestamps
    end
    add_index :users, :username_key, unique: true
    add_index :users, :email_key, unique: true
    add_check_constraint :users, "role IN ('owner', 'administrator', 'editor', 'author')", name: "users_valid_role"
    add_check_constraint :users, "auth_version >= 0", name: "users_nonnegative_auth_version"

    create_table :sites do |t|
      t.integer :singleton_key, null: false, default: 1
      t.string :install_id, limit: 36, null: false
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.string :tagline, null: false, default: ""
      t.string :canonical_origin, null: false
      t.string :locale, limit: 16, null: false, default: "en"
      t.string :timezone, limit: 80, null: false, default: "Etc/UTC"
      t.boolean :indexing_enabled, null: false, default: false
      t.string :home_mode, limit: 16, null: false, default: "static"
      t.timestamps
    end
    add_index :sites, :singleton_key, unique: true
    add_index :sites, :install_id, unique: true
    add_check_constraint :sites, "singleton_key = 1", name: "sites_singleton"
    add_check_constraint :sites, "home_mode IN ('static', 'blog')", name: "sites_valid_home_mode"

    create_table :user_sessions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, limit: 64, null: false
      t.integer :auth_version, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :user_sessions, :token_digest, unique: true

    create_table :password_resets do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, limit: 64, null: false
      t.integer :auth_version, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end
    add_index :password_resets, :token_digest, unique: true

    create_table :authentication_throttles do |t|
      t.string :key_digest, limit: 64, null: false
      t.datetime :window_started_at, null: false
      t.integer :attempts, null: false, default: 0
    end
    add_index :authentication_throttles, :key_digest, unique: true
    add_check_constraint :authentication_throttles, "attempts >= 0", name: "auth_throttles_nonnegative"
  end
end
