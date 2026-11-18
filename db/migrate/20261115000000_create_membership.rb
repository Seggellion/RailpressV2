class CreateMembership < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :membership_mode, :string, limit: 16, null: false, default: "disabled"
    add_column :sites, :member_registration_enabled, :boolean, null: false, default: false
    add_column :sites, :member_email_required, :boolean, null: false, default: true
    add_column :sites, :membership_version, :integer, null: false, default: 0
    add_check_constraint :sites, "membership_mode IN ('disabled','email','discord','both') AND membership_version >= 0", name: "site_membership_policy"
    add_check_constraint :sites, "membership_mode <> 'disabled' OR member_registration_enabled = FALSE", name: "disabled_membership_closed"
    create_table :members do |t|
      t.references :site, null: false, foreign_key: true
      t.string :public_id, limit: 36, null: false
      t.string :email, limit: 254
      t.string :email_key, limit: 64
      t.datetime :email_verified_at
      t.string :email_proof, limit: 16
      t.string :status, limit: 16, null: false, default: "active"
      t.integer :auth_version, null: false, default: 0
      t.timestamps
    end
    add_index :members, :public_id, unique: true
    add_index :members, [ :site_id, :email_key ], unique: true
    add_check_constraint :members, "status IN ('active','closed') AND auth_version >= 0", name: "member_authority"
    add_check_constraint :members, "(email IS NULL AND email_key IS NULL AND email_verified_at IS NULL AND email_proof IS NULL) OR (email IS NOT NULL AND email_key IS NOT NULL AND email_verified_at IS NOT NULL AND email_proof IN ('mailbox','discord'))", name: "member_mailbox_proof"
    create_table :member_identities do |t|
      t.references :member, null: false, foreign_key: true
      t.string :provider, limit: 16, null: false
      t.string :subject, limit: 32, null: false
      t.timestamps
    end
    add_index :member_identities, [ :provider, :subject ], unique: true
    add_index :member_identities, [ :member_id, :provider ], unique: true
    add_check_constraint :member_identities, "provider = 'discord'", name: "member_identity_provider"
    create_table :member_sessions do |t|
      t.references :member, null: false, foreign_key: true
      t.integer :auth_version, null: false
      t.string :authentication_method, limit: 16, null: false
      t.string :token_digest, limit: 64, null: false
      t.datetime :expires_at, null: false
      t.json :deadline_binding
      t.datetime :deadline_expired_at
      t.json :proof_binding, null: false
      t.datetime :proof_expires_at, null: false
      t.timestamps
    end
    add_index :member_sessions, :token_digest, unique: true
    add_check_constraint :member_sessions, "authentication_method IN ('email','discord') AND auth_version >= 0", name: "member_session_authority"
    create_table :member_challenges do |t|
      t.references :member_session, foreign_key: { on_delete: :nullify }
      t.references :site, null: false, foreign_key: true
      t.references :member, foreign_key: true
      t.string :purpose, limit: 16, null: false
      t.string :email, limit: 254, null: false
      t.string :email_key, limit: 64, null: false
      t.string :token_digest, limit: 64, null: false
      t.string :state, limit: 16, null: false, default: "pending"
      t.integer :policy_version, null: false
      t.integer :auth_version
      t.datetime :expires_at, null: false
      t.json :deadline_binding
      t.datetime :deadline_expired_at
      t.datetime :used_at
      t.timestamps
    end
    add_index :member_challenges, :token_digest, unique: true
    add_check_constraint :member_challenges, "purpose IN ('signin','change_email') AND state IN ('pending','delivered','failed','consumed')", name: "member_challenge_state"
    create_table :member_oauth_attempts do |t|
      t.references :site, null: false, foreign_key: true
      t.references :member_session, foreign_key: true
      t.string :purpose, limit: 16, null: false
      t.string :state_digest, limit: 64, null: false
      t.string :browser_digest, limit: 64, null: false
      t.string :code_digest, limit: 64
      t.text :verifier_ciphertext, null: false
      t.string :callback, limit: 512, null: false
      t.integer :policy_version, null: false
      t.datetime :expires_at, null: false
      t.json :deadline_binding
      t.datetime :deadline_expired_at
      t.datetime :used_at
      t.timestamps
    end
    add_index :member_oauth_attempts, :state_digest, unique: true
    add_index :member_oauth_attempts, :code_digest, unique: true
    add_check_constraint :member_oauth_attempts, "purpose IN ('signin','link')", name: "member_oauth_purpose"
    create_table :member_throttles do |t|
      t.string :key_digest, limit: 64, null: false
      t.integer :attempts, null: false, default: 0
      t.json :binding, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :member_throttles, :key_digest, unique: true
    add_check_constraint :member_throttles, "attempts >= 0", name: "member_throttle_count"
  end
end
