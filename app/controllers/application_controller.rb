# frozen_string_literal: true

require "ipaddr"
class ApplicationController < ActionController::Base
  layout "core"
  protect_from_forgery with: :exception, prepend: true
  prepend_before_action :core_headers
  before_action :require_https
  before_action :require_installation
  before_action -> { Privacy::PublicRequests.prepare!(self) }
  helper_method :bootstrap_state, :current_user

  rescue_from ActionController::InvalidAuthenticityToken do
    render_core_error("The form expired or could not be verified. Reload the page and try again.", status: :unprocessable_entity)
  end
  rescue_from Identity::Capabilities::Denied do
    Activity::Recorder.try_record!(actor: Current.user, action: "security.denied", outcome: "denied") if Current.user
    render_core_error("This action is not permitted.", status: :forbidden)
  end
  rescue_from Railpress::BootstrapState::Corrupt, IOError, Errno::EACCES do
    render_core_error("Private setup state is unavailable. Contact the host operator.", status: :service_unavailable)
  end
  rescue_from Railpress::SecurityClock::Unavailable do
    render_core_error("Security time could not be verified. Ask the operator to check host time and private state, then sign in again.", status: :service_unavailable)
  end
  rescue_from Activity::Recorder::Unavailable do
    render_core_error("Activity recording is unavailable. No business change was saved.", status: :service_unavailable)
  end
  rescue_from ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid do
    render_core_error("The configured site database is unavailable. Contact the host operator.", status: :service_unavailable)
  end

  private
  # Keep security decisions/statuses independent of presentation. Protected
  # browser failures use core's safe shell; non-HTML and public protocols retain
  # their original plain-text response. Never resolve a user/theme/database here.
  def render_core_error(message, status:)
    http_status = status == :unprocessable_entity ? 422 : Rack::Utils.status_code(status)
    protected_page = controller_path.start_with?("admin/") || %w[setup sessions password_recoveries members].include?(controller_path)
    if protected_page && request.format.html?
      render "shared/core_error", layout: "core", status: http_status,
        locals: { message: message, http_status: http_status }
    else
      render plain: message, status: http_status
    end
  end
  def core_headers
    Current.reset
    response.set_header("Cache-Control", "no-store")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    response.set_header("Referrer-Policy", "same-origin")
    response.set_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'none'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
  end
  def require_https
    render_core_error("HTTPS is required for setup and account access.", status: :upgrade_required) unless secure_transport?
  end
  def trusted_tls_proxy?
    peer = request.get_header("REMOTE_ADDR")
    ENV.fetch("RAILPRESS_TLS_PROXY_IPS", "").split(",").any? { |entry| IPAddr.new(entry.strip).include?(peer.to_s) }
  rescue IPAddr::InvalidAddressError
    false
  end
  def secure_transport?
    %w[https on 1].include?(request.get_header("HTTPS").to_s.downcase) ||
      (trusted_tls_proxy? && request.get_header("HTTP_X_FORWARDED_PROTO") == "https")
  end
  def client_address
    trusted_tls_proxy? ? request.remote_ip : request.get_header("REMOTE_ADDR").to_s
  end
  def bootstrap_state
    @bootstrap_state ||= Railpress::BootstrapState.for_application
  end
  def require_installation
    redirect_to setup_path, status: :see_other unless bootstrap_state.installed?
  end
  def current_user
    unless @authentication_loaded
      Current.user_session = UserSession.resolve(session[:authentication_token])
      @authentication_loaded = true
    end
    Current.user
  end
  def require_authentication
    redirect_to login_path, status: :see_other unless current_user
  end
  def authorize!(capability)
    Identity::Capabilities.require!(current_user, capability)
  end
end
