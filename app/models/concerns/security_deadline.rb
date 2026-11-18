module SecurityDeadline
  extend ActiveSupport::Concern
  included do
    before_create :bind_security_deadline
  end

  # Call under the credential row lock. The private clock journal survives even
  # if a surrounding business transaction rolls back this audit observation.
  def deadline_valid_locked?
    return false if deadline_expired_at
    return true if Railpress::SecurityClock.for_application.valid?(deadline_binding, expires_at: expires_at, ttl: self.class::LIFETIME)
    update_columns(deadline_expired_at: Time.current)
    false
  end

  def deadline_valid?
    with_lock { deadline_valid_locked? }
  end

  private
  def bind_security_deadline
    self.deadline_binding = Railpress::SecurityClock.for_application.issue(ttl: self.class::LIFETIME, expires_at: expires_at)
  end
end
