# frozen_string_literal: true

module Identity
  module PasswordRecovery
    class InvalidToken < StandardError; end
    class DeliveryUnavailable < StandardError; end
    module_function

    def mail_available?
      method = Rails.application.config.action_mailer.delivery_method
      (Rails.env.test? && ENV["RAILPRESS_TEST_MAIL_DELIVERY"] == "1" && method == :test) ||
        (!Rails.env.test? && ENV["RAILPRESS_MAIL_VERIFIED"] == "1" && method == :smtp)
    end

    def request!(identifier)
      return unless mail_available?
      field = identifier.to_s.include?("@") ? "email_key" : "username_key"
      digest = Railpress::IdentityKey.digest(identifier.to_s.byteslice(0, 254))
      RecoveryRequestJob.perform_later(field, digest)
    rescue ArgumentError
      nil
    end

    def deliver!(field, digest)
      return unless mail_available? && %w[username_key email_key].include?(field)
      user = User.find_by(field => digest)
      return unless user
      token = SecureRandom.hex(32)
      record = user.with_lock do
        user.password_resets.where(used_at: nil).update_all(used_at: Time.current)
        user.password_resets.create!(token_digest: Digest::SHA256.hexdigest(token),
          auth_version: user.auth_version, expires_at: PasswordReset::LIFETIME.from_now)
      end
      begin
        RecoveryMailer.instructions(user, token).deliver_now
      rescue StandardError
        record.update!(used_at: Time.current)
        raise DeliveryUnavailable, "Recovery delivery is unavailable", cause: nil
      end
    end

    def complete!(token:, password:, confirmation:)
      raise InvalidToken, "Invalid or expired recovery token" unless token.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(token)
      record = PasswordReset.find_by(token_digest: Digest::SHA256.hexdigest(token))
      raise InvalidToken, "Invalid or expired recovery token" unless record
      user = record.user
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        user.lock!
        record.lock!
        valid = record.used_at.nil? && record.auth_version == user.auth_version && record.deadline_valid_locked?
        raise InvalidToken, "Invalid or expired recovery token" unless valid
        Authentication.replace_password!(user, password: password, confirmation: confirmation)
      end
      user
    end
  end
end
