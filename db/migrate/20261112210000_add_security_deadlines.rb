class AddSecurityDeadlines < ActiveRecord::Migration[8.1]
  def change
    %i[user_sessions password_resets content_previews theme_previews].each do |table|
      add_column table, :deadline_binding, :json
      add_column table, :deadline_expired_at, :datetime
    end
    # Cookie carries only an opaque token. All authority remains in this row.
    create_table :navigation_previews do |t|
      t.references :menu, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.integer :auth_version, null: false
      t.integer :menu_version, null: false
      t.string :token_digest, null: false, limit: 64
      t.string :session_digest, null: false, limit: 64
      t.datetime :expires_at, null: false
      t.json :deadline_binding
      t.datetime :deadline_expired_at
      t.timestamps
    end
    add_index :navigation_previews, :token_digest, unique: true
  end
end
