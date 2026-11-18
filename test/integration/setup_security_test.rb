require "test_helper"
require_relative "../support/installation_test_support"

class SetupSecurityTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport

  def claim_setup(client = self)
    secret = @state.issue!
    token = csrf_token_for(client, "/setup")
    client.post("/setup/claim", params: { setup_secret: secret, authenticity_token: token })
    assert_equal 303, client.response.status
    csrf_token_for(client, "/setup")
  end

  test "unclaimed routes never query database and never offer arbitrary DB probing" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| queries << args.last[:sql] }
    get "/setup"
    assert_response :success
    assert_includes response.body, "Setup secret"
    refute_includes response.body, "database_host"
    %w[/login /admin /admin/users /password/recovery /password/reset].each do |path|
      get path
      assert_response :see_other
      assert_redirected_to "/setup"
    end
    post "/setup/database", params: { host: "127.0.0.1", database: "ultimacraft_test" }
    assert_response :not_found
    assert_empty queries
    refute File.exist?(File.join(@private_root, "setup.json"))
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "HTTPS CSRF and origin checks precede secret consumption" do
    secret = @state.issue!
    csrf = csrf_token_for(self, "/setup")
    post "/setup/claim", params: { setup_secret: secret }
    assert_response :unprocessable_entity
    post "/setup/claim", params: { setup_secret: secret, authenticity_token: csrf }, headers: { "Origin" => "https://attacker.example.invalid" }
    assert_response :unprocessable_entity
    https!(false)
    post "/setup/claim", params: { setup_secret: secret, authenticity_token: csrf }, headers: { "X-Forwarded-Proto" => "https" }
    assert_response :unprocessable_entity
    get "/setup", headers: { "X-Forwarded-Proto" => "https" }
    assert_response :upgrade_required
    https!
    post "/setup/claim", params: { setup_secret: secret, authenticity_token: csrf }
    assert_response :see_other
  end

  test "claim rotates cookie, only claimed setup accepts identity, setup closes permanently" do
    secret = @state.issue!
    csrf = csrf_token_for(self, "/setup")
    prior_cookie = cookies["_railpress_session"]
    post "/setup/claim", params: { setup_secret: secret, authenticity_token: csrf }
    assert_response :see_other
    refute_equal prior_cookie, cookies["_railpress_session"]
    csrf = csrf_token_for(self, "/setup")
    assert_includes response.headers["set-cookie"].to_s.downcase, "secure"
    prepare_install_schema
    Installation::Progress::STEPS[0...-1].each { |step| advance_install(self, step) }
    csrf = csrf_token_for(self, "/setup")
    post "/setup/complete", params: finish_params(csrf)
    assert_response :see_other
    assert_redirected_to "/admin"
    assert_equal 1, Site.count
    assert_equal 1, User.where(role: "owner").count
    assert @state.installed?
    get "/setup"
    assert_response :gone
    refute_includes response.body, Site.first.install_id
    post "/setup/claim", params: { setup_secret: secret }
    assert_response :unprocessable_entity
    get "/login"
    assert_includes response.body, "Sign in"
  end

  test "invalid identity rolls back owner and preserves claim" do
    claim_setup
    prepare_install_schema
    advance_install(self, "environment")
    advance_install(self, "database")
    advance_install(self, "storage")
    csrf = csrf_token_for(self, "/setup")
    revision = Installation::Progress.new(@state).read["revision"]
    post "/setup/steps/identity", params: { fields: install_fields("identity").merge("canonical_origin" => "http://unsafe.invalid"), revision: revision, authenticity_token: csrf }
    assert_response :unprocessable_entity
    assert_select 'input[name="fields[title]"]' do |nodes|
      assert_equal site_attributes[:title], nodes.first["value"]
    end
    assert_select 'input[name="fields[canonical_origin]"][value="http://unsafe.invalid"]'
    assert_equal 0, Site.count
    assert_equal 0, User.count
    refute @state.installed?
    advance_install(self, "identity")
    advance_install(self, "owner")
    advance_install(self, "appearance")
    advance_install(self, "membership")
    post "/setup/complete", params: finish_params(csrf_token_for(self, "/setup"))
    assert_response :see_other
  end

  test "two simultaneous completion requests create one site and owner" do
    csrf = review_install
    completion = finish_params(csrf)
    first = ActionDispatch::Integration::Session.new(Rails.application)
    second = ActionDispatch::Integration::Session.new(Rails.application)
    [ first, second ].each do |client|
      client.https!
      client.cookies["_railpress_session"] = cookies["_railpress_session"]
    end
    results = parallel_results(2) do |index|
      client = [ first, second ][index]
      client.post("/setup/complete", params: completion)
      client.response.status
    end
    assert_equal [ 303, 410 ], results.sort
    assert_equal 1, Site.count
    assert_equal 1, User.count
    assert @state.installed?
  end

  test "unclaimed completion and malformed state cannot trigger DB access" do
    csrf = csrf_token_for(self, "/setup")
    queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| queries << args.last[:sql] }
    post "/setup/complete", params: { site: site_attributes.merge(indexing_enabled: "0"), owner: owner_attributes, authenticity_token: csrf }
    assert_response :forbidden
    assert_empty queries
    @state.issue!
    File.open(File.join(@private_root, "setup.json"), "w", 0o600) { |file| file.write("{") }
    get "/login"
    assert_response :service_unavailable
    assert_empty queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "host headers do not set the canonical origin and protected pages are private" do
    csrf = review_install
    post "/setup/complete", params: finish_params(csrf), headers: { "Host" => "www.example.com" }
    assert_response :see_other
    assert_equal "https://publishing.example.invalid", Site.first.canonical_origin
    get "/login"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_select 'meta[name="robots"][content="noindex, nofollow"]'
  end
end
