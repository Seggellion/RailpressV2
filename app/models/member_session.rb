class MemberSession < ApplicationRecord
  include SecurityDeadline
  belongs_to :member
  LIFETIME = 1.hour
  PROOF_LIFETIME = 5.minutes
  def self.issue!(member, method:)
    raise Membership::Invalid unless member.active? && %w[email discord].include?(method)
    token = SecureRandom.hex(32)
    expiry = PROOF_LIFETIME.from_now
    create!(member: member, authentication_method: method, auth_version: member.auth_version, token_digest: Digest::SHA256.hexdigest(token), expires_at: LIFETIME.from_now,
      proof_expires_at: expiry, proof_binding: Railpress::SecurityClock.for_application.issue(ttl: PROOF_LIFETIME, expires_at: expiry))
    token
  end
  def self.resolve(token)
    return unless token.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(token)
    candidate = find_by(token_digest: Digest::SHA256.hexdigest(token))
    return unless candidate
    Membership.locked do |site|
      record = lock.find_by(id: candidate.id)
      member = Member.lock.find_by(id: candidate.member_id)
      next unless record && member&.active? && member.site_id == site.id && record.auth_version == member.auth_version && record.deadline_valid_locked? && Membership::Policy.method_allowed?(site, record.authentication_method)
      record.member = member
      record
    end
  end
  def fresh_proof?
    deadline_valid_locked? && Railpress::SecurityClock.for_application.valid?(proof_binding, expires_at: proof_expires_at, ttl: PROOF_LIFETIME)
  end
end
