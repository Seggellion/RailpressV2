require "test_helper"
require "active_job/test_helper"

class AuthenticationSecurityTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include ActiveJob::TestHelper
  setup { install_site! }

  test "login rotates the cookie and uses secure private cookie attributes" do
    csrf = csrf_token_for(self, "/login")
    old = cookies["_railpress_session"]
    post "/login", params: { identifier: @owner.username.upcase, password: PASSWORD, authenticity_token: csrf }
    assert_response :see_other
    assert_redirected_to "/admin"
    refute_equal old, cookies["_railpress_session"]
    header = response.headers["set-cookie"].to_s.downcase
    %w[secure httponly samesite=lax].each { |flag| assert_includes header, flag }
    assert_equal 1, UserSession.count
    get "/admin"
    assert_response :success
    assert_includes response.body, @owner.username
    other = ActionDispatch::Integration::Session.new(Rails.application)
    other.https!
    other.cookies["_railpress_session"] = old
    other.get("/admin")
    assert_equal 303, other.response.status
  end

  test "reauthentication revokes the previous authenticated cookie" do
    sign_in
    old = cookies["_railpress_session"]
    sign_in
    assert_equal 1, UserSession.count
    replay = ActionDispatch::Integration::Session.new(Rails.application)
    replay.https!
    replay.cookies["_railpress_session"] = old
    replay.get("/admin")
    assert_equal 303, replay.response.status
  end

  test "unknown and wrong passwords have the same generic error and cannot set role" do
    [ @owner.username, "unknown-person" ].each do |name|
      csrf = csrf_token_for(self, "/login")
      post "/login", params: { identifier: name, password: "wrong-synthetic-password", role: "owner", authenticity_token: csrf }
      assert_response :unprocessable_entity
      assert_includes response.body, "not recognized"
      refute_includes response.body, "wrong-synthetic-password"
    end
    assert_equal 0, UserSession.count
    author = create_account("author")
    sign_in(self, author)
    get "/admin/users"
    assert_response :forbidden
  end

  test "missing csrf and foreign origin cannot sign in" do
    csrf = csrf_token_for(self, "/login")
    post "/login", params: { identifier: @owner.username, password: PASSWORD }
    assert_response :unprocessable_entity
    post "/login", params: { identifier: @owner.username, password: PASSWORD, authenticity_token: csrf }, headers: { "Origin" => "https://attacker.example.invalid" }
    assert_response :unprocessable_entity
    assert_equal 0, UserSession.count
  end

  test "logout revokes replayed cookies and requires CSRF" do
    sign_in
    csrf = csrf_token_for(self, "/admin")
    bearer_cookie = cookies["_railpress_session"]
    delete "/logout"
    assert_response :unprocessable_entity
    assert_equal 1, UserSession.count
    delete "/logout", params: { authenticity_token: csrf }
    assert_response :see_other
    assert_equal 0, UserSession.count
    replay = ActionDispatch::Integration::Session.new(Rails.application)
    replay.https!
    replay.cookies["_railpress_session"] = bearer_cookie
    replay.get("/admin")
    assert_equal 303, replay.response.status
  end

  test "expired sessions, version mismatch and tampered cookies deny access" do
    sign_in
    travel 13.hours do
      get "/admin"
      assert_response :see_other
      assert_redirected_to "/login"
    end
    sign_in
    @owner.update_column(:auth_version, @owner.auth_version + 1)
    get "/admin"
    assert_response :see_other
    sign_in
    cookies["_railpress_session"] = cookies["_railpress_session"].to_s + "tampered"
    get "/admin"
    assert_response :see_other
  end

  test "login attempts are bounded and the window recovers" do
    10.times do
      csrf = csrf_token_for(self, "/login")
      post "/login", params: { identifier: @owner.username, password: "wrong-synthetic-password", authenticity_token: csrf }
      assert_response :unprocessable_entity
    end
    csrf = csrf_token_for(self, "/login")
    post "/login", params: { identifier: @owner.username, password: PASSWORD, authenticity_token: csrf }
    assert_response :too_many_requests
    travel 11.minutes do
      sign_in
      assert_response :see_other
    end
  end

  test "exhausted IP budget cannot keep allocating identity buckets" do
    20.times do |index|
      csrf = csrf_token_for(self, "/login")
      post "/login", params: { identifier: "unknown#{index}", password: "wrong-synthetic-password", authenticity_token: csrf }
      assert_response :unprocessable_entity
    end
    count = AuthenticationThrottle.count
    csrf = csrf_token_for(self, "/login")
    post "/login", params: { identifier: "another-unknown", password: PASSWORD, authenticity_token: csrf }
    assert_response :too_many_requests
    assert_equal count, AuthenticationThrottle.count
  end

  test "recovery is generic and honestly unavailable without mail" do
    get "/password/recovery"
    assert_includes response.body, "not configured"
    [ @owner.username, "nobody" ].each do |identifier|
      csrf = csrf_token_for(self, "/password/recovery")
      post "/password/recovery", params: { identifier: identifier, authenticity_token: csrf }
      assert_response :accepted
      assert_includes response.body, "If recovery email is available"
    end
    assert_equal 0, PasswordReset.count
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  test "enabled test mail sends paste token without putting it in URLs or job arguments" do
    ENV["RAILPRESS_TEST_MAIL_DELIVERY"] = "1"
    csrf = csrf_token_for(self, "/password/recovery")
    assert_enqueued_jobs 1, only: RecoveryRequestJob do
      post "/password/recovery", params: { identifier: @owner.email, authenticity_token: csrf }
    end
    assert_response :accepted
    job = enqueued_jobs.last
    refute_includes job[:args].to_s, @owner.email
    perform_enqueued_jobs
    assert_equal 1, ActionMailer::Base.deliveries.count
    token = ActionMailer::Base.deliveries.last.body.decoded[/[a-f0-9]{64}/]
    assert token
    refute_includes response.body, token
    refute_includes response.headers["Location"].to_s, token
    assert_equal Digest::SHA256.hexdigest(token), PasswordReset.first.token_digest
    sign_in
    cookie = cookies["_railpress_session"]
    csrf = csrf_token_for(self, "/password/reset")
    patch "/password/reset", params: { recovery_token: token, password: "replacement-synthetic-phrase!", password_confirmation: "replacement-synthetic-phrase!", authenticity_token: csrf }
    assert_response :see_other
    assert_equal 0, UserSession.count
    replay = ActionDispatch::Integration::Session.new(Rails.application)
    replay.https!
    replay.cookies["_railpress_session"] = cookie
    replay.get("/admin")
    assert_equal 303, replay.response.status
    csrf = csrf_token_for(self, "/password/reset")
    patch "/password/reset", params: { recovery_token: token, password: PASSWORD, password_confirmation: PASSWORD, authenticity_token: csrf }
    assert_response :unprocessable_entity
    assert @owner.reload.authenticate("replacement-synthetic-phrase!")
  end

  test "reset rejects missing CSRF, weak passwords and expired tokens without changing credentials" do
    token = create_recovery_token
    patch "/password/reset", params: { recovery_token: token, password: PASSWORD, password_confirmation: PASSWORD }
    assert_response :unprocessable_entity
    refute PasswordReset.first.used_at
    assert_raises(ActiveRecord::RecordInvalid) { Identity::PasswordRecovery.complete!(token: token, password: "short", confirmation: "short") }
    assert_nil PasswordReset.first.reload.used_at
    travel 16.minutes do
      assert_raises(Identity::PasswordRecovery::InvalidToken) { Identity::PasswordRecovery.complete!(token: token, password: PASSWORD, confirmation: PASSWORD) }
    end
    assert @owner.reload.authenticate(PASSWORD)
  end

  test "all protected pages are non-indexable and cannot redirect to an external return URL" do
    get "/login", params: { return_to: "https://attacker.example.invalid" }
    sign_in
    assert_redirected_to "/admin"
    %w[/admin /admin/users /admin/settings /login /password/reset].each do |path|
      get path
      assert_response :success
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
      assert_select "script:not([src])", count: 0
      assert_select 'script[src*="admin_shell"]', count: path.start_with?("/admin") ? 1 : 0
    end
  end
end
