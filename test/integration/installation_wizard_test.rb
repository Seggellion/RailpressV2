require "test_helper"
require_relative "../support/installation_test_support"

class InstallationWizardTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport
  def replacing(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name, replacement)
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end

  test "complete wizard publishes honest starter Dusk menus and seals with Owner session" do
    csrf = review_install
    get "/setup"
    refute_includes response.body, IdentityTestSupport::PASSWORD
    refute_includes response.body, "$2a$"
    assert_select 'input[type="password"]', count: 0
    post "/setup/complete", params: finish_params(csrf)
    assert_response :see_other
    assert_redirected_to "/admin"
    assert_equal 1, Site.count
    assert_equal 1, User.count
    assert_equal 3, Page.publicly_visible.count
    assert_equal [ "draft" ], Post.pluck(:status)
    assert_equal "dusk", ThemeState.first.active_installation.theme_key
    assert_equal 3, MenuLocation.where.not(published_menu_id: nil).count
    assert_equal 0, ThemePreview.count
    assert_equal 1, UserSession.count
    refute Site.first.indexing_enabled
    refute File.read(File.join(@private_root, "installation.json")).include?("password_digest")
    get "/admin"
    assert_response :ok
    get "/"
    assert_response :ok
    assert_select '[data-dusk-family="front"]'
    assert_includes response.body, "A new beginning"
    assert_select 'link[rel="canonical"][href="https://publishing.example.invalid/"]'
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    get "/setup"
    assert_response :gone
  end

  test "skipping steps legacy finish and stale or foreign progress are rejected" do
    secret = @state.issue!
    claim = @state.claim!(secret)
    wizard = Installation::Wizard.new(@state)
    value = wizard.start!(claim)
    assert_raises(Installation::Progress::Invalid) { Installation::Finish.call(state: @state, claim: claim, revision: value["revision"]) }
    assert_raises(Installation::Progress::Invalid) { wizard.advance!(claim: claim, revision: value["revision"], step: "owner", fields: owner_attributes) }
    wizard.advance!(claim: claim, revision: value["revision"], step: "environment")
    assert_raises(Installation::Progress::Conflict) { wizard.advance!(claim: claim, revision: value["revision"], step: "environment") }
    assert_equal 0, User.count
    assert_equal 0, Site.count
  end

  test "malicious database choices never reach a network probe or persist credentials" do
    prepare_install_schema
    claim = @state.claim!(@state.issue!)
    wizard = Installation::Wizard.new(@state)
    wizard.start!(claim)
    wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: "environment")
    fields = install_fields("database").merge("host" => "169.254.169.254", "password" => "SECRET-CANARY")
    calls = 0
    replacing(Installation::DatabaseProbe, :call, -> { calls += 1; raise "unexpected probe" }) do
      assert_raises(Installation::Configuration::Handoff) { wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: "database", fields: fields) }
    end
    assert_equal 0, calls
    refute File.read(File.join(@private_root, "installation.json")).include?("SECRET-CANARY")
    original = Installation::Configuration.fingerprint
    config = Installation::Configuration.active.merge("password" => "SECRET-CANARY")
    replacing(Installation::Configuration, :active, -> { config }) { assert_equal original, Installation::Configuration.fingerprint }
  end

  test "back navigation invalidates downstream approval without leaking owner verifier" do
    csrf = review_install
    progress = Installation::Progress.new(@state)
    assert progress.read.dig("data", "owner", "password_digest")
    advance_install(self, "identity", fields: install_fields("identity").merge("title" => "Reviewed again"))
    assert_equal %w[environment database storage identity], progress.read["completed"]
    get "/setup?step=review"
    assert_select "h1", text: "Your keys. Your website."
    refute_includes response.body, "$2a$"
    post "/setup/complete", params: finish_params(csrf_token_for(self, "/setup"))
    assert_response :unprocessable_entity
    assert_equal 0, User.count
  end

  test "reissued token resumes choices but removes prior Owner credentials" do
    review_install
    old = Installation::Progress.new(@state).read
    second = @state.claim!(@state.issue!)
    fresh = Installation::Wizard.new(@state).start!(second)
    assert_equal old["attempt_id"], fresh["attempt_id"]
    assert_equal old.dig("data", "identity"), fresh.dig("data", "identity")
    assert_nil fresh.dig("data", "owner")
    assert_equal [], fresh["completed"]
  end

  test "doctor observes without database queries or filesystem changes" do
    @state.issue!
    before = Dir[File.join(@private_root, "**", "*")].select { |file| File.file?(file) }.to_h { |file| [ file, Digest::SHA256.file(file).hexdigest ] }
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| queries << args.last[:sql] }
    result = Installation::Cli.doctor(@state)
    assert_equal false, result["repairs_performed"]
    assert_equal false, result["database_probed"]
    assert_empty queries
    after = Dir[File.join(@private_root, "**", "*")].select { |file| File.file?(file) }.to_h { |file| [ file, Digest::SHA256.file(file).hexdigest ] }
    assert_equal before, after
    refute JSON.generate(result).include?(Installation::Configuration.active["password"])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
