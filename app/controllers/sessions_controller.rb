# frozen_string_literal: true

class SessionsController < ApplicationController
  def new
  end
  def create
    identifier = params[:identifier].to_s
    ip_allowed = AuthenticationThrottle.consume?(scope: "login-ip", identity: client_address, limit: 20, window: 10.minutes)
    unless ip_allowed
      Activity::Recorder.try_record!(actor: nil, action: "security.rate_limited", outcome: "denied")
      return render_core_error("Too many attempts. Try again later.", status: :too_many_requests)
    end
    account_allowed = AuthenticationThrottle.consume?(scope: "login-identity", identity: Railpress::IdentityKey.digest(identifier.byteslice(0, 254)), limit: 10, window: 10.minutes)
    unless account_allowed
      Activity::Recorder.try_record!(actor: nil, action: "security.rate_limited", outcome: "denied")
      return render_core_error("Too many attempts. Try again later.", status: :too_many_requests)
    end
    user = Identity::Authentication.authenticate(identifier: identifier, password: params[:password])
    unless user
      Activity::Recorder.try_record!(actor: nil, action: "security.login_failed", outcome: "denied")
      @error = "The username/email or password was not recognized."
      return render :new, status: :unprocessable_entity
    end
    handoff = if user.owner? && (intent = session[:module_catalog_intent])
      Extensions::CatalogHandoff.sign_in_return(intent, site: Site.find_by!(singleton_key: 1), base_url: request.base_url)
    end
    token = UserSession.issue!(user, replacing: session[:authentication_token])
    reset_session
    session[:authentication_token] = token
    redirect_to(handoff ? admin_module_catalog_path(handoff) : admin_path, status: :see_other)
  rescue UserSession::StaleIdentity
    @error = "The username/email or password was not recognized."
    render :new, status: :unprocessable_entity
  rescue ArgumentError
    render_core_error("The sign-in request could not be accepted.", status: :unprocessable_entity)
  end
  def destroy
    require_authentication
    return if performed?
    actor = current_user
    Site.transaction do
      Site.find_by!(singleton_key: 1).lock!
      Current.user_session.destroy!
      Activity::Recorder.try_record!(actor: actor, action: "security.logout", subject: actor)
    end
    reset_session
    redirect_to login_path, notice: "You are signed out.", status: :see_other
  end
end
