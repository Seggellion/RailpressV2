class MembersController < ApplicationController
  before_action :load_site
  before_action :require_member, only: %i[show change_email disconnect close export]
  rescue_from Membership::Invalid, Membership::Collision, ActiveRecord::RecordNotUnique do
    membership_error("Verification could not be accepted. Use a fresh link or sign in to your existing Member account before linking.", :unprocessable_entity)
  end
  rescue_from Membership::Unavailable do
    membership_error("This member verification method is unavailable or registration is closed. Staff sign-in and Owner recovery remain separate.", :service_unavailable)
  end
  rescue_from Membership::RateLimited do
    membership_error("Too many verification requests. Wait before trying again.", :too_many_requests)
  end
  def new
    @methods = Membership::Policy.enabled_methods(@site.membership_mode)
  end
  def request_email
    Membership::EmailVerification.request!(browser: (session[:member_email_browser] ||= SecureRandom.hex(32)), address: params[:email], client: client_address)
    redirect_to members_verify_path, notice: "If this method is available, a single-use link will arrive. Delivery can fail; requesting a link does not verify an account.", status: :see_other
  end
  def verify
  end
  def complete_email
    member, token = Membership::EmailVerification.complete!(browser: session[:member_email_browser], token: params[:verification_token], member_session: member_session)
    accept_member(member, token)
  end
  def start_discord
    current = params[:purpose] == "link" ? member_session : nil
    raise Membership::Invalid if params[:purpose] == "link" && !current
    session[:member_oauth_browser] = SecureRandom.hex(32)
    target = Membership::Discord.start!(browser: session[:member_oauth_browser], client: client_address,
      member_session: current, confirmation: params[:confirmation] == "1")
    # A form redirect is itself governed by form-action in Chrome. Keep the
    # strict policy and require an ordinary explicit link from a core handoff.
    response.set_header("Referrer-Policy", "no-referrer")
    response.set_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'none'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
    @discord_authorization_url = target
    destination = URI.parse(target)
    @discord_destination_host = destination.host
    @discord_email_requested = URI.decode_www_form(destination.query.to_s).to_h.fetch("scope", "").split.include?("email")
    @discord_linking = !current.nil?
    render :discord_handoff
  end
  def discord_callback
    raise Membership::Invalid unless request.base_url == @site.canonical_origin && params[:error].nil?
    member, token = Membership::Discord.complete!(state: params[:state], code: params[:code], issuer: params[:iss],
      browser: session.delete(:member_oauth_browser), callback: request.base_url + request.path)
    accept_member(member, token)
  end
  def show
    @member = member_session.member
  end
  def change_email
    Membership::EmailVerification.request!(browser: (session[:member_email_browser] ||= SecureRandom.hex(32)), address: params[:email], client: client_address, member_session: member_session)
    redirect_to members_verify_path, notice: "Confirm the new mailbox in this same signed-in browser. Fresh account proof is required.", status: :see_other
  end
  def disconnect
    member, token = Membership::Discord.disconnect!(session: member_session, confirmation: params[:confirmation] == "1")
    accept_member(member, token)
  end
  def destroy
    if (record = member_session)
      Membership.locked do
        MemberOauthAttempt.where(member_session_id: record.id).delete_all
        record.destroy!
      end
    end
    reset_session
    redirect_to members_login_path, notice: "Your Member session is signed out.", status: :see_other
  end
  def close
    Membership.locked do
      record = member_session
      record.lock!
      member = record.member
      member.lock!
      raise Membership::Invalid unless params[:confirmation] == "1" && record.auth_version == member.auth_version && record.fresh_proof?
      Membership.revoke!(member)
      member.update!(status: "closed")
    end
    reset_session
    redirect_to members_login_path, notice: "Membership closed and sessions revoked. The documented operator retention policy applies; this is not an instant erasure claim.", status: :see_other
  end
  def export
    member = member_session.member
    render json: { format: "railpress.member.v1", profile: member.attributes.slice("public_id", "email", "email_verified_at", "email_proof", "status", "created_at"),
      identities: member.member_identities.map { |identity| identity.attributes.slice("provider", "subject") } }
  end
  private
  def core_headers
    super
    # Same-origin form submissions must send their origin for Rails CSRF verification.
    response.set_header("Referrer-Policy", "no-referrer") if %w[discord_callback export].include?(action_name)
    response.set_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'none'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
  end
  def load_site
    return if performed?
    @site = Site.find_by!(singleton_key: 1)
  end
  def member_session
    return @member_session if defined?(@member_session)
    @member_session = MemberSession.resolve(session[:member_authentication_token])
  end
  def require_member
    redirect_to members_login_path, status: :see_other unless member_session
  end
  def accept_member(_member, token)
    reset_session
    session[:member_authentication_token] = token
    @member_session = nil
    redirect_to members_account_path, notice: "Member verification accepted. This account has no staff privileges.", status: :see_other
  end
  def membership_error(message, status)
    @error = message
    @methods = @site ? Membership::Policy.enabled_methods(@site.membership_mode) : []
    render :new, status: status
  end
end
