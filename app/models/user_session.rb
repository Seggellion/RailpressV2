# frozen_string_literal: true

class UserSession < ApplicationRecord
  include SecurityDeadline
  belongs_to :user
  class StaleIdentity < StandardError; end
  LIFETIME = 12.hours

  def self.issue!(user, replacing: nil)
    authenticated_version = user.auth_version
    authenticated_digest = user.password_digest
    token = SecureRandom.hex(32)
    Site.transaction do
      Site.find_by!(singleton_key: 1).lock!
      user.lock!
      unless user.auth_version == authenticated_version && user.password_digest == authenticated_digest
        raise StaleIdentity, "Sign in again with the current credentials"
      end
      if replacing.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(replacing)
        where(token_digest: Digest::SHA256.hexdigest(replacing)).delete_all
      end
      create!(user: user, token_digest: Digest::SHA256.hexdigest(token),
        auth_version: user.auth_version, expires_at: LIFETIME.from_now)
      Activity::Recorder.record!(actor: user, action: "security.login", subject: user)
    end
    token
  rescue ActiveRecord::RecordNotFound
    raise StaleIdentity, "Sign in again with the current credentials"
  end

  def self.resolve(token)
    return unless token.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(token)
    candidate = find_by(token_digest: Digest::SHA256.hexdigest(token))
    return unless candidate
    transaction do
      user = User.lock.find_by(id: candidate.user_id)
      record = lock.find_by(id: candidate.id)
      next unless user && record && record.auth_version == user.auth_version && record.deadline_valid_locked?
      record.user = user
      record
    end
  end
end
