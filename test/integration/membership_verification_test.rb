require "test_helper"
require_relative "../support/membership_test_support"
class MembershipVerificationTest < ActionDispatch::IntegrationTest
  include MembershipTestSupport
  test "disabled default leaves staff Owner recovery independent and no provider calls on anonymous browsing" do
    assert_equal "disabled", Site.first.membership_mode
    refute Site.first.member_registration_enabled
    get "/login/members/login"
    assert_response :ok
    assert_select 'input[name="email"]', count: 0
    assert_select 'form[action="/login/members/discord"]', count: 0
    assert_includes response.body, "Public membership is disabled"
    %w[/ /blog /search /robots.txt /sitemap.xml].each { |path| get path; refute_equal 500, response.status }
    assert_empty @providers.messages
    assert_empty @providers.exchanges
    sign_in
    assert_redirected_to "/admin"
    assert_equal 1, User.count
    assert_equal 0, Member.count
    assert_equal [ "owner" ], User.pluck(:role)
  end
  test "all four policies require explicit activation and readiness with optimistic Owner authority" do
    %w[disabled email discord both].each do |mode|
      configure_membership(mode, enabled: false)
      assert_equal mode, Site.first.membership_mode
      refute Site.first.member_registration_enabled
    end
    assert_raises(Membership::Invalid) { configure_membership("email_and_discord") }
    assert_raises(Membership::Unavailable) { configure_membership("disabled") }
    @providers.email_ready = false
    assert_raises(Membership::Unavailable) { configure_membership("both") }
    assert_raises(Membership::Unavailable) { configure_membership("email") }
    configure_membership("discord")
    assert Site.first.member_registration_enabled
    revision = Site.first.membership_version
    assert_raises(Membership::Conflict) { configure_membership("discord", revision: revision - 1) }
    assert_equal revision, Site.first.membership_version
    %w[administrator editor author].each do |role|
      assert_raises(Identity::Capabilities::Denied) { configure_membership("discord", actor: create_account(role)) }
    end
    assert_equal 0, Member.count
  end
  test "mailbox accepted only after delivery and explicit one-use signed proof without staff elevation" do
    configure_membership("email")
    Membership::EmailVerification.request!(browser: "c" * 64, address: " READER@EXAMPLE.INVALID ", client: "synthetic-ip")
    assert_equal 0, Member.count
    proof = @providers.messages.last.fetch(:token)
    row = MemberChallenge.last
    assert_equal "delivered", row.state
    assert_equal "reader@example.invalid", row.email
    refute_includes row.attributes.to_json, proof
    assert_equal 2, row.deadline_binding.fetch("version")
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "d" * 64, token: proof) }
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: proof + "tamper") }
    member, credential = Membership::EmailVerification.complete!(browser: "c" * 64, token: proof)
    assert_equal "mailbox", member.email_proof
    assert_equal 1, Member.count
    assert_equal member, MemberSession.resolve(credential).member
    refute Identity::Capabilities.allowed?(member, :admin)
    assert_equal 1, User.count
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: proof) }
    assert_equal 1, Member.count
  end
  test "SMTP failures resend invalidation and rate bounds cannot create verified accounts" do
    configure_membership("email")
    @providers.mail_failure = true
    assert_nil Membership::EmailVerification.request!(browser: "c" * 64, address: "reader@example.invalid", client: "synthetic-ip")
    assert_equal "failed", MemberChallenge.last.state
    assert_equal 0, Member.count
    @providers.mail_failure = false
    Membership::EmailVerification.request!(browser: "c" * 64, address: "reader@example.invalid", client: "synthetic-ip")
    old = @providers.messages.last.fetch(:token)
    Membership::EmailVerification.request!(browser: "c" * 64, address: "reader@example.invalid", client: "synthetic-ip")
    fresh = @providers.messages.last.fetch(:token)
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: old) }
    assert_raises(Membership::RateLimited) { Membership::EmailVerification.request!(browser: "c" * 64, address: "reader@example.invalid", client: "another-synthetic-ip") }
    assert_equal 3, MemberChallenge.count
    member, = Membership::EmailVerification.complete!(browser: "c" * 64, token: fresh)
    assert_equal "reader@example.invalid", member.email
  end
  test "invalid mail and purpose audience signatures fail closed and expired proof stays invalid" do
    configure_membership("email")
    [ "invalid", "a\n@example.invalid", "a" * 255, "\xFF".b ].each do |address|
      assert_raises(Membership::Invalid, ArgumentError) { Membership::EmailVerification.request!(browser: "c" * 64, address: address, client: "test") }
    end
    Membership::EmailVerification.request!(browser: "c" * 64, address: "reader@example.invalid", client: "test")
    token = @providers.messages.last.fetch(:token)
    foreign = Membership::EmailVerification.signer.generate({ "audience" => SecureRandom.uuid, "purpose" => "signin", "nonce" => "x" }, purpose: "member-mailbox")
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: foreign) }
    travel 16.minutes do
      assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: token) }
    end
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: token) }
    assert_equal 0, Member.count
  end
  test "simultaneous mailbox consumption creates exactly one Member and session" do
    configure_membership("email")
    Membership::EmailVerification.request!(browser: "c" * 64, address: "reader@example.invalid", client: "test")
    token = @providers.messages.last.fetch(:token)
    results = parallel_results(2) do
      Membership::EmailVerification.complete!(browser: "c" * 64, token: token)
      :accepted
    rescue Membership::Invalid
      :refused
    end
    assert_equal [ :accepted, :refused ], results.sort
    assert_equal 1, Member.count
    assert_equal 1, MemberSession.count
  end
  test "OAuth exact issuer callback browser state and code are required before exchange" do
    configure_membership("discord")
    url = oauth_start
    query = URI.decode_www_form(URI.parse(url).query).to_h
    assert_equal "discord.com", URI.parse(url).host
    assert_equal "code", query["response_type"]
    assert_equal "S256", query["code_challenge_method"]
    assert_equal "identify email", query["scope"]
    assert_equal Site.first.canonical_origin + "/login/members/discord/callback", query["redirect_uri"]
    data = @providers.authorize(url)
    base = data.merge(browser: "a" * 64, callback: query["redirect_uri"])
    [ { issuer: "https://attacker.invalid" }, { issuer: nil }, { browser: "b" * 64 }, { state: "b" * 64 }, { callback: "https://attacker.invalid/callback" } ].each do |wrong|
      assert_raises(Membership::Invalid) { Membership::Discord.complete!(**base.merge(wrong)) }
    end
    assert_empty @providers.exchanges
    member, token = Membership::Discord.complete!(**base)
    assert_equal "discord", member.email_proof
    assert_equal member, MemberSession.resolve(token).member
    assert_equal "123456789012345678", member.member_identities.first.subject
    assert_raises(Membership::Invalid) { Membership::Discord.complete!(**base) }
    assert_equal 1, @providers.exchanges.length
    assert_equal 1, User.count
  end
  test "PKCE failure and duplicate code burn attempts without credential replay" do
    configure_membership("discord")
    url = oauth_start
    data = @providers.authorize(url, nil, challenge: "mismatched", code: "synthetic-reused-code")
    assert_raises(Membership::Invalid) { Membership::Discord.complete!(**data, browser: "a" * 64, callback: Site.first.canonical_origin + "/login/members/discord/callback") }
    assert MemberOauthAttempt.first.used_at
    assert_equal 0, Member.count
    second = oauth_start
    repeated = @providers.authorize(second, nil, code: "synthetic-reused-code")
    assert_raises(Membership::Invalid) { Membership::Discord.complete!(**repeated, browser: "a" * 64, callback: Site.first.canonical_origin + "/login/members/discord/callback") }
    assert_equal 1, @providers.exchanges.length
  end
  test "forged provider payload absent or unverified email never creates an email-required identity" do
    configure_membership("discord")
    [ { "id" => 123456789 }, { "id" => "bad" }, { "id" => "123456789", "email" => "reader@example.invalid", "verified" => false }, { "id" => "123456789", "verified" => true }, { "id" => "123456789", "email" => "reader@example.invalid", "verified" => true, "bot" => true } ].each do |payload|
      assert_raises(Membership::Invalid) { oauth_complete(oauth_start, payload) }
    end
    assert_equal 0, Member.count
    configure_membership("discord", required_email: false)
    member, = oauth_complete(oauth_start, { "id" => "123456789", "username" => "owner", "role" => "owner", "email" => "not-requested@example.invalid", "verified" => true })
    assert_nil member.email
    assert_equal [ "identify" ], @providers.exchanges.last[:scopes]
    assert_equal 1, User.count
    refute Identity::Capabilities.allowed?(member, :manage_identity)
  end
  test "same mailbox never merges Discord accounts and linking needs fresh current explicit proof" do
    configure_membership
    member, token = verified_member
    session = MemberSession.resolve(token)
    assert_raises(Membership::Collision) { oauth_complete(oauth_start) }
    assert_raises(Membership::Invalid) { oauth_start(member_session: session) }
    linked, = oauth_complete(oauth_start(member_session: session, confirmation: true))
    assert_equal member.id, linked.id
    assert_equal 1, Member.count
    assert_equal 1, MemberIdentity.count
    assert_raises(Membership::Collision) { oauth_complete(oauth_start(member_session: session, confirmation: true), { "id" => "999999999999999999", "email" => member.email, "verified" => true }) }
    travel 6.minutes do
      assert_raises(Membership::Invalid) { oauth_start(member_session: session, confirmation: true) }
    end
  end
  test "identify-only sign-in requests matching email only for explicit account linking" do
    configure_membership("both", required_email: false)
    member, token = verified_member
    current = MemberSession.resolve(token)
    [ { "id" => "123456789012345678" },
      { "id" => "123456789012345678", "email" => member.email, "verified" => false },
      { "id" => "123456789012345678", "email" => "other@example.invalid", "verified" => true } ].each do |payload|
      url = oauth_start(member_session: current, confirmation: true)
      assert_equal "identify email", URI.decode_www_form(URI.parse(url).query).to_h["scope"]
      assert_raises(Membership::Invalid) { oauth_complete(url, payload) }
      assert_equal 0, MemberIdentity.count
    end
    url = oauth_start(member_session: current, confirmation: true)
    linked, = oauth_complete(url)
    assert_equal member.id, linked.id
    assert_equal %w[identify email], @providers.exchanges.last[:scopes]
    assert_equal 1, Member.count
    assert_equal 1, MemberIdentity.count
    ordinary = oauth_start
    assert_equal "identify", URI.decode_www_form(URI.parse(ordinary).query).to_h["scope"]
    signed_in, = oauth_complete(ordinary, { "id" => "123456789012345678" })
    assert_equal member.id, signed_in.id
    assert_equal "reader@example.invalid", signed_in.email
    assert_equal [ "identify" ], @providers.exchanges.last[:scopes]
    assert_equal [ "owner" ], User.pluck(:role)
    get "/login/members/account"
    assert_redirected_to "/login/members/login"
  end

  test "two concurrent explicit Discord links cannot replace the first saved identity" do
    configure_membership
    member, token = verified_member
    session = MemberSession.resolve(token)
    requests = 2.times.map do |index|
      url = oauth_start(browser: (index.zero? ? "a" : "b") * 64, member_session: session, confirmation: true)
      @providers.authorize(url, { "id" => (index.zero? ? "111111111111111111" : "222222222222222222"), "email" => member.email, "verified" => true })
    end
    result = with_competing_link_snapshots do
      parallel_results(2) do |index|
        Membership::Discord.complete!(**requests[index], browser: (index.zero? ? "a" : "b") * 64, callback: Site.first.canonical_origin + "/login/members/discord/callback")
        :accepted
      rescue Membership::Collision
        :refused
      end
    end
    assert_equal [ :accepted, :refused ], result.sort
    assert_equal 1, MemberIdentity.count
    assert_equal 1, Member.count
  end
  test "closed membership revokes pending mailbox proof and prevents re-enrollment" do
    configure_membership("email")
    member, = verified_member
    csrf = csrf_token_for(self, "/login/members/login")
    post "/login/members/email", params: { email: member.email, authenticity_token: csrf }
    proof = @providers.messages.last[:token]
    post "/login/members/verify", params: { verification_token: proof, authenticity_token: csrf_token_for(self, "/login/members/verify") }
    assert_redirected_to "/login/members/account"
    Membership::EmailVerification.request!(browser: "c" * 64, address: member.email, client: "test")
    pending = @providers.messages.last[:token]
    post "/login/members/close", params: { confirmation: "1", authenticity_token: csrf_token_for(self, "/login/members/account") }
    assert_redirected_to "/login/members/login"
    assert_equal "closed", member.reload.status
    assert_equal 0, MemberSession.count
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: pending) }
    assert_equal 1, User.count
  end
  test "disconnect requires separate mailbox proof and revokes all old sessions" do
    configure_membership
    member, token = verified_member
    session = MemberSession.resolve(token)
    oauth_complete(oauth_start(member_session: session, confirmation: true))
    assert_raises(Membership::Invalid) { Membership::Discord.disconnect!(session: session, confirmation: false) }
    kept, fresh = Membership::Discord.disconnect!(session: session, confirmation: true)
    assert_equal member.id, kept.id
    assert_equal 0, MemberIdentity.count
    assert_nil MemberSession.resolve(token)
    assert_equal member.id, MemberSession.resolve(fresh).member_id
  end
  test "provider identity is stable across rename and changed email or revocation is safe" do
    configure_membership("discord")
    member, = oauth_complete(oauth_start)
    same, = oauth_complete(oauth_start, { "id" => "123456789012345678", "username" => "A new name", "email" => member.email, "verified" => true })
    assert_equal member.id, same.id
    assert_raises(Membership::Invalid) { oauth_complete(oauth_start, { "id" => "123456789012345678", "email" => "changed@example.invalid", "verified" => true }) }
    assert_equal "reader@example.invalid", member.reload.email
    @providers.exchange_failure = true
    assert_raises(Membership::Unavailable) { oauth_complete(oauth_start) }
    assert_equal 1, Member.count
    assert_equal 1, MemberIdentity.count
  end
  test "policy update revokes Member sessions and pending proofs without touching staff sessions" do
    configure_membership
    member, token = verified_member
    staff_token = UserSession.issue!(@owner)
    Membership::EmailVerification.request!(browser: "c" * 64, address: "another@example.invalid", client: "test")
    pending = @providers.messages.last[:token]
    configure_membership("disabled", enabled: false)
    assert_nil MemberSession.resolve(token)
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: pending) }
    assert UserSession.resolve(staff_token)
    assert_equal member.id, Member.first.id
  end
  test "new registration may close while existing mailbox access remains available" do
    configure_membership("email")
    member, = verified_member
    configure_membership("email", enabled: false)
    same, = verified_member
    assert_equal member.id, same.id
    Membership::EmailVerification.request!(browser: "c" * 64, address: "new-reader@example.invalid", client: "test")
    assert_raises(Membership::Unavailable) { Membership::EmailVerification.complete!(browser: "c" * 64, token: @providers.messages.last[:token]) }
    assert_equal 1, Member.count
  end
  test "mailbox changes require same fresh authenticated browser and cannot steal another Member" do
    configure_membership("email")
    member, token = verified_member
    session = MemberSession.resolve(token)
    Membership::EmailVerification.request!(browser: "c" * 64, address: "new@example.invalid", client: "test", member_session: session)
    proof = @providers.messages.last[:token]
    assert_raises(Membership::Invalid) { Membership::EmailVerification.complete!(browser: "c" * 64, token: proof) }
    changed, fresh = Membership::EmailVerification.complete!(browser: "c" * 64, token: proof, member_session: session)
    assert_equal member.id, changed.id
    assert_equal "new@example.invalid", changed.email
    assert_nil MemberSession.resolve(token)
    assert_equal changed.id, MemberSession.resolve(fresh).member_id
  end
  test "core routes enforce CSRF noindex no-store and Member credentials cannot access staff" do
    configure_membership("email")
    csrf = csrf_token_for(self, "/login/members/login")
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    origin = request.base_url
    post "/login/members/email", params: { email: "reader@example.invalid" }, headers: { "Origin" => origin }
    assert_response :unprocessable_entity
    [ "null", "https://unrelated.example.invalid" ].each do |received_origin|
      post "/login/members/email", params: { authenticity_token: csrf, email: "reader@example.invalid" }, headers: { "Origin" => received_origin }
      assert_response :unprocessable_entity
    end
    assert_empty @providers.messages
    post "/login/members/email", params: { authenticity_token: csrf, email: "reader@example.invalid", role: "owner" },
      headers: { "Origin" => origin }
    assert_response :see_other
    assert_redirected_to "/login/members/verify"
    proof = @providers.messages.last[:token]
    get "/login/members/verify"
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    assert_select 'link[rel="canonical"]', count: 0
    assert_select 'meta[name="robots"][content="noindex, nofollow"]'
    assert_equal 0, Member.count
    post "/login/members/verify", params: { verification_token: proof, authenticity_token: csrf_token_for(self, "/login/members/verify") },
      headers: { "Origin" => origin }
    assert_redirected_to "/login/members/account"
    get "/login/members/account"
    assert_response :ok
    get "/login/members/export"
    assert_response :ok
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    refute_match(/token_digest|deadline_binding|password|client_secret|auth_version/, response.body)
    get "/admin/accounts"
    assert_redirected_to "/login"
    assert_equal 1, User.count
    assert_equal "owner", User.first.role
    delete "/login/members/logout", params: { authenticity_token: csrf_token_for(self, "/login/members/account") }
    assert_redirected_to "/login/members/login"
    assert_equal 0, MemberSession.count
  end
  test "new and existing mailboxes share the public response even when SMTP delivery fails" do
    configure_membership("email")
    verified_member("existing@example.invalid")
    notices = []
    [ false, true ].each do |failed|
      @providers.mail_failure = failed
      %w[existing@example.invalid new@example.invalid].each do |address|
        csrf = csrf_token_for(self, "/login/members/login")
        post "/login/members/email", params: { email: address, authenticity_token: csrf }
        assert_response :see_other
        assert_redirected_to "/login/members/verify"
        notices << flash[:notice]
        assert_equal failed ? "failed" : "delivered", MemberChallenge.last.state
        assert_equal 1, Member.count
      end
    end
    assert_equal 1, notices.uniq.size
    assert_includes notices.first, "If this method is available"
  end
  test "Owner Accounts endpoints deny every other staff role and stale configuration" do
    %w[administrator editor author].each do |role|
      actor = create_account(role)
      client = open_session; client.https!
      sign_in(client, actor)
      client.get "/admin/accounts"
      assert_equal 403, client.response.status
      client.patch "/admin/accounts", params: { revision: Site.first.membership_version, accounts: { membership_mode: "both" }, authenticity_token: csrf_token_for(client, "/admin") }
      assert_equal 403, client.response.status
    end
    sign_in
    csrf = csrf_token_for(self, "/admin/accounts")
    patch "/admin/accounts", params: { revision: -1, accounts: { membership_mode: "email" }, authenticity_token: csrf }
    assert_response :conflict
    assert_equal "disabled", Site.first.membership_mode
  end
  test "Discord uses a core explicit handoff while preserving strict form CSP and no authority" do
    host! URI.parse(Site.first.canonical_origin).host
    configure_membership("discord")
    csrf = csrf_token_for(self, "/login/members/login")
    post "/login/members/discord", params: { authenticity_token: csrf, return_to: "https://evil.invalid/steal" }
    assert_response :ok
    assert_nil response.headers["Location"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_includes response.headers["Content-Security-Policy"], "form-action 'self'"
    assert_includes response.headers["Content-Security-Policy"], "script-src 'none'"
    assert_select "script", count: 0
    assert_select 'meta[http-equiv="refresh"]', count: 0
    document = Nokogiri::HTML(response.body)
    link = document.at_css("a[data-discord-handoff]")
    destination = URI.parse(link["href"])
    assert_equal "https", destination.scheme
    assert_equal "discord.com", destination.host
    assert_equal "/oauth2/authorize", destination.path
    assert_equal "noreferrer noopener", link["rel"]
    fields = URI.decode_www_form(destination.query).to_h
    assert_equal "identify email", fields["scope"]
    assert_equal "S256", fields["code_challenge_method"]
    refute fields.key?("client_secret")
    refute fields.key?("code_verifier")
    refute_includes response.body, "evil.invalid"
    assert_select 'a[href="/login/members/login"]', text: "Cancel and return"
    assert_empty @providers.exchanges
    assert_equal 0, Member.count
    assert_equal 0, MemberSession.count
    assert_equal 1, MemberOauthAttempt.count
    assert_equal [ "owner" ], User.pluck(:role)
  end
  test "explicit link handoff requests matching mailbox and completes only after callback" do
    host! URI.parse(Site.first.canonical_origin).host
    configure_membership("both", required_email: false)
    csrf = csrf_token_for(self, "/login/members/login")
    post "/login/members/email", params: { authenticity_token: csrf, email: "reader@example.invalid" }
    proof = @providers.messages.last.fetch(:token)
    post "/login/members/verify", params: { verification_token: proof, authenticity_token: csrf_token_for(self, "/login/members/verify") }
    assert_redirected_to "/login/members/account"
    post "/login/members/discord", params: { purpose: "link", confirmation: "1", authenticity_token: csrf_token_for(self, "/login/members/account") }
    assert_response :ok
    document = Nokogiri::HTML(response.body)
    target = document.at_css("a[data-discord-handoff]")["href"]
    assert_equal "identify email", URI.decode_www_form(URI.parse(target).query).to_h["scope"]
    assert_includes response.body, "verified email claim"
    assert_select 'a[href="/login/members/account"]', text: "Cancel and return"
    assert_equal 0, MemberIdentity.count
    assert_empty @providers.exchanges
    data = @providers.authorize(target)
    get "/login/members/discord/callback", params: { state: data[:state], code: data[:code], iss: data[:issuer] }
    assert_redirected_to "/login/members/account"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal 1, Member.count
    assert_equal 1, MemberIdentity.count
    assert_equal [ "owner" ], User.pluck(:role)
  end
  test "member route prefix cannot be claimed by public content or forged callback origin" do
    refute Railpress::ContentRoutes.reserved_content_slug?("Page", "members")
    assert Railpress::ContentRoutes.reserved_content_slug?("Page", "login/members/discord/callback")
    configure_membership("discord")
    csrf = csrf_token_for(self, "/login/members/login")
    post "/login/members/discord", params: { authenticity_token: csrf }
    assert_response :ok
    destination = Nokogiri::HTML(response.body).at_css("a[data-discord-handoff]")["href"]
    assert_equal "discord.com", URI.parse(destination).host
    data = @providers.authorize(destination)
    get "/login/members/discord/callback", params: { state: data[:state], code: data[:code], iss: "https://evil.invalid" }
    assert_response :unprocessable_entity
    assert_empty @providers.exchanges
  end
end
