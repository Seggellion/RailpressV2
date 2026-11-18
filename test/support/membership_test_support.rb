require_relative "identity_test_support"
module MembershipTestSupport
  extend ActiveSupport::Concern
  include IdentityTestSupport
  class SyntheticProviders < Membership::Providers
    attr_accessor :email_ready, :discord_ready, :mail_failure, :exchange_failure
    attr_reader :messages, :exchanges
    def initialize
      @email_ready = @discord_ready = true
      @messages = []; @codes = {}; @exchanges = []
    end
    def status(method, origin:) = ready?(method, origin: origin) ? "synthetic_verified" : "unavailable"
    def ready?(method, origin:) = method == "email" ? email_ready : method == "discord" && discord_ready
    def discord_settings(origin:)
      raise Membership::Unavailable unless discord_ready
      { "client_id" => "123456789012345678", "client_secret" => "SYNTHETIC-NOT-A-LIVE-SECRET", "callback" => origin + "/login/members/discord/callback" }
    end
    def authorization_url(fields) = "https://discord.com/oauth2/authorize?" + URI.encode_www_form(fields)
    def deliver_email(address:, token:, origin:)
      raise Membership::Unavailable if mail_failure || !email_ready
      @messages << { address: address, token: token, origin: origin }
      true
    end
    def authorize(url, payload = nil, code: SecureRandom.hex(16), challenge: nil)
      fields = URI.decode_www_form(URI.parse(url).query).to_h
      raise "fixture requires exact PKCE" unless fields["code_challenge_method"] == "S256"
      @codes[code] = { challenge: challenge || fields.fetch("code_challenge"), payload: payload || { "id" => "123456789012345678", "email" => "reader@example.invalid", "verified" => true } }
      { state: fields.fetch("state"), code: code, issuer: "https://discord.com" }
    end
    def exchange(code:, verifier:, origin:, scopes:)
      @exchanges << { origin: origin, scopes: scopes }
      raise Membership::Unavailable if exchange_failure || !discord_ready
      item = @codes.delete(code)
      raise Membership::Invalid unless item && Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) == item[:challenge]
      item.fetch(:payload)
    end
  end
  included do
    setup do
      @previous_membership_adapter = Rails.application.config.x.membership_provider_adapter
      @providers = SyntheticProviders.new
      Rails.application.config.x.membership_provider_adapter = @providers
      install_site!
    end
    teardown { Rails.application.config.x.membership_provider_adapter = @previous_membership_adapter }
  end
  # Exercise caller-established repeatable-read views as well as ordinary service
  # transactions. Current authority must come from locking reads, not old views.
  def with_competing_link_snapshots
    original_locked = Membership.method(:locked)
    original_exchange = @providers.method(:exchange)
    mutex = Mutex.new
    condition = ConditionVariable.new
    arrivals = 0
    Membership.define_singleton_method(:locked) do |&operation|
      Site.transaction do
        if Thread.current[:a05_link_after_exchange] && !Thread.current[:a05_link_snapshot_seen]
          Site.first
          Thread.current[:a05_link_snapshot_seen] = true
          mutex.synchronize do
            arrivals += 1
            if arrivals == 2
              condition.broadcast
            else
              condition.wait(mutex, 20)
              raise "Concurrency snapshot barrier timeout" unless arrivals == 2
            end
          end
        end
        original_locked.call(&operation)
      end
    end
    @providers.define_singleton_method(:exchange) do |**fields|
      payload = original_exchange.call(**fields)
      Thread.current[:a05_link_after_exchange] = true
      payload
    end
    yield
  ensure
    Membership.define_singleton_method(:locked, original_locked) if original_locked
    @providers.define_singleton_method(:exchange, original_exchange) if original_exchange
  end

  def configure_membership(mode = "both", enabled: true, required_email: true, actor: @owner, revision: Site.first.membership_version)
    Membership::Policy.configure!(actor: actor, revision: revision, fields: { "membership_mode" => mode, "member_registration_enabled" => enabled ? "1" : "0", "member_email_required" => required_email ? "1" : "0" })
  end
  def verified_member(address = "reader@example.invalid")
    Membership::EmailVerification.request!(browser: "c" * 64, address: address, client: "synthetic-ip")
    Membership::EmailVerification.complete!(browser: "c" * 64, token: @providers.messages.last.fetch(:token))
  end
  def oauth_start(browser: "a" * 64, member_session: nil, confirmation: false)
    Membership::Discord.start!(browser: browser, client: "synthetic-ip", member_session: member_session, confirmation: confirmation)
  end
  def oauth_complete(url, payload = nil, browser: "a" * 64, **options)
    data = @providers.authorize(url, payload, **options)
    Membership::Discord.complete!(**data, browser: browser, callback: Site.first.canonical_origin + "/login/members/discord/callback")
  end
end
