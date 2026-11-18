# frozen_string_literal: true

module Identity
  module Authentication
    module_function
    def find_user(identifier)
      field = identifier.to_s.include?("@") ? :email_key : :username_key
      User.find_by(field => Railpress::IdentityKey.digest(identifier))
    rescue ArgumentError
      nil
    end

    def authenticate(identifier:, password:)
      return unless identifier.is_a?(String) && identifier.bytesize <= 254 && password.is_a?(String) && password.bytesize.between?(1, 72)
      field = identifier.include?("@") ? :email_key : :username_key
      User.authenticate_by(field => Railpress::IdentityKey.digest(identifier), password: password)
    rescue ArgumentError
      nil
    end

    def replace_password!(user, password:, confirmation:)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        user.lock!
        user.update!(password: password, password_confirmation: confirmation, auth_version: user.auth_version + 1)
        user.user_sessions.delete_all
        user.password_resets.where(used_at: nil).update_all(used_at: Time.current)
        Activity::Recorder.record!(actor: user, action: "security.password_changed", subject: user)
      end
    end
  end
end
