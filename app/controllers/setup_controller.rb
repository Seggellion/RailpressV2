# frozen_string_literal: true

class SetupController < ApplicationController
  skip_before_action :require_installation
  before_action :reject_installed

  rescue_from Railpress::BootstrapState::Closed do
    reset_session
    render_core_error("Setup is closed.", status: :gone)
  end
  rescue_from Railpress::BootstrapState::InvalidClaim do
    reset_session
    @claimed = false
    @error = "The setup secret or claim is invalid or expired. Ask the host operator for a new secret."
    render :show, status: :forbidden
  end
  rescue_from Setup::Complete::Conflict do
    render_core_error("Setup stopped safely. The host operator must review the existing site data.", status: :conflict)
  end
  rescue_from Installation::Progress::Conflict do |error|
    setup_error(error.message, :conflict)
  end
  rescue_from Installation::Progress::Invalid, Installation::Configuration::Handoff, Installation::Schema::Refused,
    Installation::DatabaseProbe::Unavailable, Installation::DatabaseProbe::Unsafe, MediaLibrary::Configuration::Handoff, Railpress::MediaConfiguration::Invalid do |error|
    setup_error(error.message, :unprocessable_entity)
  end
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Railpress::ThemePackage::Invalid, Railpress::ThemeSmoke::Rejected do
    setup_error("Installation did not finish. No partial website was published. Ask the operator to inspect the private configuration and trusted Dusk package.", :unprocessable_entity)
  end

  def show
    load_wizard
  end

  def claim
    nonce = bootstrap_state.claim!(params[:setup_secret])
    reset_session
    session[:setup_claim] = nonce
    wizard.start!(nonce)
    redirect_to setup_path, status: :see_other
  end

  def advance
    wizard.advance!(claim: session[:setup_claim], revision: params[:revision], step: params[:step], fields: (params[:fields] || ActionController::Parameters.new).permit(
      :adapter, :host, :port, :database, :username, :password, :password_confirmation, :tls, :use_operator_credentials,
      :title, :tagline, :canonical_origin, :timezone, :locale, :home_mode, :indexing_enabled, :email, :brand_label, :about, :contact, :membership_mode, :member_registration_enabled, :member_email_required, :backend, :project, :bucket, :prefix, :auth_method, :identity_source, :storage_limits_ack).to_h)
    redirect_to setup_path, status: :see_other
  end

  def storage_guide
    render :storage_guide
  end

  def complete
    owner = Installation::Finish.call(state: bootstrap_state, claim: session[:setup_claim], revision: params[:revision])
    token = UserSession.issue!(owner)
    reset_session
    session[:authentication_token] = token
    redirect_to admin_path, notice: "Welcome to Railpress. Your site is ready; review Site Readiness before sharing it.", status: :see_other
  end

  private
  def wizard = @wizard ||= Installation::Wizard.new(bootstrap_state)

  def load_wizard
    @claimed = bootstrap_state.claimed?(session[:setup_claim])
    return unless @claimed
    @progress = wizard.redacted
    requested = params[:step].to_s
    allowed = @progress["completed"] + [ @progress["step"] ]
    @step = allowed.include?(requested) ? requested : @progress["step"]
    @fields = @progress["data"][@step] || {}
    @environment = Installation::Environment.call if @step == "environment" || @step == "review"
    @connection = Installation::Configuration.public_fields if @step == "database"
    if @step == "storage" || @step == "review"
      selected = @progress.dig("data", "storage")
      @storage = MediaLibrary::Configuration.observe(selected)
    end
    @origin = Installation::Configuration.canonical_origin if @step == "identity"
  end

  def setup_error(message, status)
    @error = message
    load_wizard
    if @claimed && params[:fields].is_a?(ActionController::Parameters) && params[:step] == @step
      # Keep only unsaved, non-secret form entries in this response; never persist them.
      submitted = params[:fields].permit(:title, :tagline, :canonical_origin, :timezone, :locale, :home_mode,
        :indexing_enabled, :username, :email, :brand_label, :about, :contact, :membership_mode, :member_registration_enabled, :member_email_required, :backend, :project, :bucket, :prefix, :auth_method, :identity_source, :storage_limits_ack, :adapter, :host, :port, :database, :tls).to_h
      @fields = (@fields || {}).merge(submitted)
      @connection = @connection.merge(submitted.slice(*@connection.keys)) if @connection
    end
    render :show, status: status
  end

  def reject_installed
    render_core_error("Setup is closed.", status: :gone) if bootstrap_state.installed?
  end
end
