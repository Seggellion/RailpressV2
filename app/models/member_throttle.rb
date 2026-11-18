class MemberThrottle < ApplicationRecord
  def self.consume!(scope:, identity:, limit:, window:)
    key = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "member:#{scope}:#{identity}")
    entry = find_by(key_digest: key)
    clock = Railpress::SecurityClock.for_application
    unless entry && clock.valid?(entry.binding, expires_at: entry.expires_at, ttl: window)
      entry ||= new(key_digest: key)
      entry.expires_at = window.from_now
      entry.binding = clock.issue(ttl: window, expires_at: entry.expires_at)
      entry.attempts = 0
    end
    raise Membership::RateLimited if entry.attempts >= limit
    entry.update!(attempts: entry.attempts + 1)
    true
  end
end
