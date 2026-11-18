require "test_helper"
require_relative "../support/membership_test_support"
class MembershipSecurityTest < ActiveSupport::TestCase
  include MembershipTestSupport
  def replacing(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name, replacement)
    yield
  ensure
    object.define_singleton_method(name, original)
  end
  test "normalized mailbox length remains bounded after Unicode case folding" do
    assert_operator ("İ" * 100 + "@example.invalid").bytesize, :<=, 254
    assert_raises(Membership::Invalid) { Membership.email("İ" * 100 + "@example.invalid") }
  end

  test "real elapsed expiry survives frozen wall time and new boot or lost authority refuses old proofs" do
    configure_membership("email")
    ticks = 100.0
    domain = "synthetic-member-domain"
    clock = Railpress::SecurityClock.new(@private_root, elapsed: -> { ticks }, domain: -> { domain })
    replacing(Railpress::SecurityClock, :for_application, -> { clock }) do
      travel_to Time.utc(2026, 11, 14, 12) do
        Membership::EmailVerification.request!(browser: "c" * 64, address: "elapsed@example.invalid", client: "test")
        token = @providers.messages.last[:token]
        ticks += 901
        assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: token) }
        assert_equal 0, Member.count
        Membership::EmailVerification.request!(browser: "c" * 64, address: "reboot@example.invalid", client: "test")
        token = @providers.messages.last[:token]
        domain = "synthetic-new-boot"
        assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: token) }
        Membership::EmailVerification.request!(browser: "c" * 64, address: "authority@example.invalid", client: "test")
        token = @providers.messages.last[:token]
        path = File.join(@private_root, "security-clock.json")
        assert File.realpath(path).start_with?(Rails.root.join(".local/state/m02-tests").realpath.to_s + "/")
        File.unlink(path) # Synthetic private-journal loss injection, never host clock mutation.
        assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: token) }
        assert_equal 0, Member.count
      end
    end
  end
  test "email and OAuth retention cleanup uses the deadline authority and preserves fresh rows" do
    configure_membership
    Membership::EmailVerification.request!(browser: "c" * 64, address: "reader@example.invalid", client: "test")
    oauth_start
    assert_equal 1, MemberChallenge.count
    assert_equal 1, MemberOauthAttempt.count
    Membership.cleanup!
    assert_equal 1, MemberChallenge.count
    assert_equal 1, MemberOauthAttempt.count
    travel 16.minutes do
      Membership.cleanup!
      assert_equal 0, MemberChallenge.count
      assert_equal 0, MemberOauthAttempt.count
    end
  end
  test "pinned Discord transport refuses SSRF redirects and any unapproved destination before network" do
    [ [ "127.0.0.1" ], [ "10.0.0.1" ], [ "2606:4700::1111", "::1" ], [ "169.254.169.254" ] ].each do |ips|
      transport = Membership::DiscordTransport.new(resolver: ->(_host) { ips })
      replacing(Net::HTTP, :new, ->(*) { raise "Unexpected real network" }) do
        assert_raises(Membership::Unavailable) { transport.request("https://discord.com/api/oauth2/token", form: { "code" => "synthetic" }) }
      end
    end
    transport = Membership::DiscordTransport.new(resolver: ->(_host) { [ "1.1.1.1" ] })
    [ "http://discord.com/api/oauth2/token", "https://discord.com.evil.invalid/api/oauth2/token", "https://u:p@discord.com/api/oauth2/token", "https://discord.com/api/oauth2/token?next=evil", "https://discord.com/api/oauth2/token/revoke/../token", "https://evil.invalid" ].each do |url|
      assert_raises(Membership::Unavailable) { transport.request(url, form: {}) }
    end
  end
  class FakeConnection
    attr_accessor :ipaddr, :use_ssl, :verify_mode, :verify_hostname, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :requests
    def initialize(response)
      @response = response
      @socket = Struct.new(:io).new(StringIO.new)
      @requests = []
    end
    def start = yield(self)
    def request(value)
      @requests << value
      yield @response
    end
  end
  class FakeResponse
    def initialize(code: "200", headers: {}, chunks: [ "{\"id\":\"123456789\"}" ])
      @code, @headers, @chunks = code, { "content-type" => "application/json" }.merge(headers), chunks
    end
    attr_reader :code
    def [](key) = @headers[key]
    def read_body = @chunks.each { |chunk| yield chunk }
  end
  test "Discord transport pins IP verifies TLS bounds bytes and refuses redirects compression and invalid JSON" do
    transport = Membership::DiscordTransport.new(resolver: ->(_host) { [ "1.1.1.1" ] })
    positive = FakeConnection.new(FakeResponse.new)
    replacing(Net::HTTP, :new, ->(*) { positive }) do
      assert_equal "123456789", transport.request("https://discord.com/api/v10/users/@me", bearer: "synthetic-bearer")["id"]
    end
    assert_equal "1.1.1.1", positive.ipaddr
    assert_equal true, positive.verify_hostname
    assert_equal OpenSSL::SSL::VERIFY_PEER, positive.verify_mode
    assert_equal 0, positive.max_retries
    assert_equal 2, positive.read_timeout
    assert_equal "Bearer synthetic-bearer", positive.requests.first["Authorization"]
    [ FakeResponse.new(code: "302"), FakeResponse.new(code: "401"), FakeResponse.new(headers: { "content-encoding" => "gzip" }), FakeResponse.new(headers: { "content-length" => "16385" }), FakeResponse.new(chunks: [ "x" * 16385 ]), FakeResponse.new(chunks: [ "[]" ]), FakeResponse.new(chunks: [ "bad json" ]) ].each do |response|
      replacing(Net::HTTP, :new, ->(*) { FakeConnection.new(response) }) do
        assert_raises(Membership::Unavailable) { transport.request("https://discord.com/api/v10/users/@me", bearer: "synthetic-bearer") }
      end
    end
  end
  test "stale Owner authentication cannot change policy after password or authority revocation" do
    previous = Site.first.membership_version
    User.where(id: @owner.id).update_all(auth_version: @owner.auth_version + 1)
    assert_raises(Identity::Capabilities::Denied) { configure_membership }
    assert_equal previous, Site.first.membership_version
  end
  test "unconfigured Rails custom options cannot masquerade as a trusted provider adapter" do
    previous = Rails.application.config.x.membership_provider_adapter
    Rails.application.config.x.membership_provider_adapter = ActiveSupport::OrderedOptions.new
    assert_instance_of Membership::Providers, Membership::Providers.current
    assert_equal "unavailable", Membership::Providers.current.status("email", origin: Site.first.canonical_origin)
  ensure
    Rails.application.config.x.membership_provider_adapter = previous
  end
  test "host provider configuration cannot be populated from Site fields or unsafe files" do
    previous = ENV["RAILPRESS_MEMBERSHIP_CONFIG"]
    ENV.delete("RAILPRESS_MEMBERSHIP_CONFIG")
    providers = Membership::Providers.new
    refute providers.ready?("email", origin: Site.first.canonical_origin)
    refute providers.ready?("discord", origin: Site.first.canonical_origin)
    path = File.join(@private_root, "synthetic-providers.json")
    File.write(path, "{}", perm: 0o644)
    ENV["RAILPRESS_MEMBERSHIP_CONFIG"] = path
    assert_raises(Membership::Unavailable) { providers.document }
    File.chmod(0o600, path)
    assert_equal({}, providers.document)
    File.write(path, JSON.generate({ "discord" => { "verified" => true, "client_id" => "123456789", "client_secret" => "SYNTHETIC-ONLY-NO-LIVE-KEY", "callback" => "https://evil.invalid/callback", "pkce_s256_verified" => true } }))
    refute providers.ready?("discord", origin: Site.first.canonical_origin)
  ensure
    ENV["RAILPRESS_MEMBERSHIP_CONFIG"] = previous
  end
  test "confidential provider validates token scopes and revokes a transient grant even on refusal" do
    provider = Membership::Providers.new
    settings = { "client_id" => "123456789", "client_secret" => "SYNTHETIC-NOT-A-LIVE-SECRET", "callback" => Site.first.canonical_origin + "/login/members/discord/callback" }
    calls = []
    returned_scope = "identify email"
    transport = Object.new
    transport.define_singleton_method(:request) do |url, **fields|
      calls << { url: url, fields: fields }
      if url.end_with?("/token")
        { "access_token" => "synthetic-access-token", "token_type" => "Bearer", "scope" => returned_scope }
      elsif url.end_with?("/revoke")
        {}
      else
        { "id" => "123456789", "email" => "reader@example.invalid", "verified" => true }
      end
    end
    replacing(provider, :discord_settings, ->(origin:) { settings }) do
      replacing(Membership::DiscordTransport, :new, -> { transport }) do
        assert_equal "123456789", provider.exchange(code: "synthetic-code", verifier: "synthetic-verifier", origin: Site.first.canonical_origin, scopes: %w[identify email])["id"]
        assert_equal 3, calls.length
        assert_equal "authorization_code", calls.first[:fields][:form]["grant_type"]
        assert_equal "synthetic-verifier", calls.first[:fields][:form]["code_verifier"]
        assert_equal settings["callback"], calls.first[:fields][:form]["redirect_uri"]
        calls.clear
        returned_scope = "identify email guilds"
        assert_raises(Membership::Unavailable) { provider.exchange(code: "synthetic-code", verifier: "synthetic-verifier", origin: Site.first.canonical_origin, scopes: %w[identify email]) }
        assert_equal 2, calls.length
        assert calls.last[:url].end_with?("/revoke")
      end
    end
  end
  test "expired exchange budget cannot start a fresh revocation budget" do
    provider = Membership::Providers.new
    settings = { "client_id" => "123456789", "client_secret" => "SYNTHETIC-NOT-A-LIVE-SECRET", "callback" => "https://deadline.example.invalid/login/members/discord/callback" }
    now = 100.0
    calls = []
    transport = Object.new
    transport.define_singleton_method(:request) do |url, **_fields|
      calls << url
      if url.end_with?("/token")
        { "access_token" => "synthetic-bearer", "token_type" => "Bearer", "scope" => "identify" }
      elsif url.end_with?("/revoke")
        raise "revocation must not start after budget exhaustion"
      else
        now += 5
        raise Membership::Unavailable
      end
    end
    replacing(provider, :elapsed_now, -> { now }) do
      replacing(provider, :discord_settings, ->(origin:) { settings }) do
        replacing(Membership::DiscordTransport, :new, -> { transport }) do
          assert_raises(Membership::Unavailable) { provider.exchange(code: "synthetic-code", verifier: "synthetic-verifier", origin: "https://deadline.example.invalid", scopes: [ "identify" ]) }
        end
      end
    end
    assert_equal 2, calls.length
    refute calls.any? { |url| url.end_with?("/revoke") }
  end
  test "cleanup returning after the absolute sequence budget cannot accept a payload" do
    provider = Membership::Providers.new
    settings = { "client_id" => "123456789", "client_secret" => "SYNTHETIC-NOT-A-LIVE-SECRET", "callback" => "https://deadline.example.invalid/login/members/discord/callback" }
    now = 100.0
    calls = []
    transport = Object.new
    transport.define_singleton_method(:request) do |url, **_fields|
      calls << url
      if url.end_with?("/token")
        { "access_token" => "synthetic-bearer", "token_type" => "Bearer", "scope" => "identify" }
      elsif url.end_with?("/revoke")
        now = 105.0
        {}
      else
        now = 104.0
        { "id" => "123456789" }
      end
    end
    replacing(provider, :elapsed_now, -> { now }) do
      replacing(provider, :discord_settings, ->(origin:) { settings }) do
        replacing(Membership::DiscordTransport, :new, -> { transport }) do
          assert_raises(Membership::Unavailable) { provider.exchange(code: "synthetic-code", verifier: "synthetic-verifier", origin: "https://deadline.example.invalid", scopes: [ "identify" ]) }
        end
      end
    end
    assert_equal 3, calls.length
    assert calls.last.end_with?("/revoke")
  end
  test "provider configuration rotation refuses a pending callback before backchannel exchange" do
    configure_membership("discord")
    url = oauth_start
    data = @providers.authorize(url)
    settings = @providers.discord_settings(origin: Site.first.canonical_origin).merge("client_secret" => "ROTATED-SYNTHETIC-SECRET")
    replacing(@providers, :discord_settings, ->(origin:) { settings }) do
      assert_raises(Membership::Invalid) { Membership::Discord.complete!(**data, browser: "a" * 64, callback: Site.first.canonical_origin + "/login/members/discord/callback") }
    end
    assert_empty @providers.exchanges
    assert_equal 0, Member.count
  end
  test "all pending tokens and provider metadata are filtered and ordinary content export excludes Member authority" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    keys = %w[code state verification_token code_verifier client_secret access_token refresh_token email error_description]
    redacted = filter.filter(keys.to_h { |key| [ key, "SYNTHETIC-SECRET-CANARY" ] })
    keys.each { |key| refute_includes redacted[key], "SYNTHETIC-SECRET-CANARY" }
    configure_membership
    verified_member
    snapshot = Portability::Snapshot.new(Site.first, { "mode" => "public", "menus" => false, "appearance" => false }).capture
    refute_match(/member_registration|membership_mode|member_email_required|client_secret|token_digest|deadline_binding|reader@example.invalid/, JSON.generate(snapshot))
  end
end
