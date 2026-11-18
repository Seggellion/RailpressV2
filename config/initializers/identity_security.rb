# frozen_string_literal: true

Rails.application.config.session_store :cookie_store, key: "_railpress_session",
  secure: true, httponly: true, same_site: :lax
Rails.application.config.action_controller.forgery_protection_origin_check = true
Rails.application.config.filter_parameters += %i[q query search]
Rails.application.config.filter_parameters += %i[identifier username email password password_confirmation password_digest setup_secret setup_claim authentication_token recovery_token token_digest claim_digest secret_digest]

# Rails mail LogSubscriber uses Base.logger, so subclass-only suppression is insufficient.
ActiveSupport.on_load(:action_mailer) { self.logger = nil }

ActionDispatch::ExceptionWrapper.rescue_responses["Railpress::UploadBodyLimit::TooLarge"] = "payload_too_large"
