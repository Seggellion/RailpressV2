# frozen_string_literal: true

class AuthenticationThrottle < ApplicationRecord
  def self.consume?(scope:, identity:, limit:, window:)
    key = Digest::SHA256.hexdigest("#{scope}:#{identity}")
    entry = create_or_find_by!(key_digest: key) { |item| item.window_started_at = Time.current; item.attempts = 0 }
    entry.with_lock do
      if entry.window_started_at <= Time.current - window
        entry.window_started_at = Time.current
        entry.attempts = 0
      end
      if entry.attempts >= limit
        false
      else
        entry.update!(attempts: entry.attempts + 1)
        true
      end
    end
  end
end
