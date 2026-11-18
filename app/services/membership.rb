module Membership
  class Invalid < StandardError; end
  class Unavailable < StandardError; end
  class RateLimited < StandardError; end
  class Conflict < StandardError; end
  class Collision < StandardError; end
  def self.locked
    Site.transaction do
      site = Site.lock.find_by!(singleton_key: 1)
      yield site
    end
  end
  def self.digest(value) = Digest::SHA256.hexdigest(value.to_s)
  def self.email(value)
    raise Invalid unless value.is_a?(String) && value.bytesize <= 254
    normalized = Railpress::IdentityKey.normalize(value.encode(Encoding::UTF_8))
    raise Invalid unless normalized.bytesize <= 254 && URI::MailTo::EMAIL_REGEXP.match?(normalized) && !normalized.match?(/[\x00-\x20\x7f]/)
    normalized
  rescue ArgumentError, EncodingError
    raise Invalid, "Invalid mailbox", cause: nil
  end
  def self.revoke!(member)
    member.update!(auth_version: member.auth_version + 1)
    ids = member.member_sessions.pluck(:id)
    MemberOauthAttempt.where(member_session_id: ids).delete_all
    member.member_sessions.delete_all
    MemberChallenge.where(member_id: member.id).or(MemberChallenge.where(site_id: member.site_id, email_key: member.email_key)).update_all(used_at: Time.current, state: "consumed")
  end
  def self.cleanup!
    locked { cleanup_locked! }
  end
  def self.cleanup_locked!
    clock = Railpress::SecurityClock.for_application
    [ MemberChallenge, MemberOauthAttempt ].each do |type|
      type.order(:id).limit(50).lock.each do |row|
        row.destroy! unless row.deadline_valid_locked?
      end
    end
    MemberSession.order(:id).limit(50).lock.each do |row|
      next if row.deadline_valid_locked?
      MemberOauthAttempt.where(member_session_id: row.id).delete_all
      row.destroy!
    end
    MemberThrottle.order(:id).limit(50).lock.each do |row|
      row.destroy! unless clock.valid?(row.binding, expires_at: row.expires_at, ttl: 1.hour)
    end
  end
  def self.prune!
    cleanup_locked!
    raise Unavailable if [ MemberChallenge, MemberOauthAttempt, MemberThrottle ].any? { |type| type.count >= 2000 }
  end
end
