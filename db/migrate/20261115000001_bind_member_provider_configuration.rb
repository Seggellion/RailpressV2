class BindMemberProviderConfiguration < ActiveRecord::Migration[8.1]
  def change
    # Any old in-flight attempt lacks a matching fingerprint and fails closed.
    add_column :member_challenges, :browser_digest, :string, limit: 64
    add_column :member_oauth_attempts, :provider_fingerprint, :string, limit: 64
  end
end
