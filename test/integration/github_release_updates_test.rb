require "test_helper"
require_relative "../support/release_test_support"
require_relative "../support/theme_test_support"

class GithubReleaseUpdatesTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  include ReleaseTestSupport
  setup do
    release_setup
    travel_back
    @saved_update_env = ENV.to_h.slice("RAILPRESS_RELEASE_PUBLIC_TRUST", "RAILPRESS_NATIVE_PUBLIC_STATUS", "RAILPRESS_DEPLOYMENT_ID")
    ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"] = File.join(@operator_root, "trust.json")
    @old_theme = stage("dusk", version: "1.0.0")
    @old_overlay = Themes::Manager.overlay!(actor: @owner, installation: @old_theme, attributes: { footer: "Keep this footer", brand_label: "Synthetic site" })
    activate(@old_theme, @old_overlay)
    @theme_contract = [ Releases::Combined.theme_identity(@old_theme) ]
    @release_fixture = build_release(channel: "alpha")
    @metadata = { "manifest" => @release_fixture["manifest"], "signature" => @release_fixture["signature"],
      "version" => @release_fixture["manifest"]["version"],
      "package_url" => "https://github.com/Seggellion/RailpressV2/releases/download/v2.0.0-alpha.2/package.tar.gz",
      "plan_url" => "https://github.com/Seggellion/RailpressV2/releases/download/v2.0.0-alpha.2/native-plan.json" }
    @source = Object.new
    @source.define_singleton_method(:releases) { [ "published release only" ] }
    data = @metadata
    @source.define_singleton_method(:metadata) { |_| data }
  end
  teardown do
    %w[RAILPRESS_RELEASE_PUBLIC_TRUST RAILPRESS_NATIVE_PUBLIC_STATUS RAILPRESS_DEPLOYMENT_ID].each { |key| ENV[key] = @saved_update_env[key] }
    release_teardown
  end
  def refresh
    Releases::Catalog.configure!(actor: @owner, enabled: true, channel: "alpha")
    Releases::Catalog.refresh!(source: @source)
  end
  def combined_host
    ENV["RAILPRESS_DEPLOYMENT_ID"] = SecureRandom.uuid
    ENV["RAILPRESS_NATIVE_PUBLIC_STATUS"] = File.join(@operator_root, "native-status.json")
    statement = { "format" => "railpress.host-status.v1", "scope" => "isolated-synthetic-nginx-v1", "production_qualified" => false,
      "independent_utc_qualified" => false, "deployment_id" => ENV["RAILPRESS_DEPLOYMENT_ID"], "capabilities" => %w[preflight promote revert],
      "generation" => 1, "active_release" => "a" * 64, "previous_release" => nil, "observed_elapsed" => Railpress::SecurityClock.elapsed,
      "domain" => Railpress::SecurityClock.boot_domain, "combined_protocol" => Releases::Combined::PROTOCOL,
      "combined_ready" => true, "backup_verified" => true, "restore_drill_completed" => true, "snapshot_id" => SecureRandom.uuid }
    File.write(ENV["RAILPRESS_NATIVE_PUBLIC_STATUS"], JSON.generate("statement" => statement, "signature" => signed(statement, @status_signer)), perm: 0o600)
  end
  test "product family and channels are independent and prereleases order numerically" do
    assert_equal "2.0.0-alpha.1", Railpress::Product::VERSION
    assert_equal "alpha", Railpress::Product::CHANNEL
    assert_operator Railpress::Releases.compare_versions("2.0.0-alpha.10", "2.0.0-alpha.2"), :>, 0
    assert_operator Railpress::Releases.compare_versions("2.0.0", "2.0.0-alpha.99"), :>, 0
    stable = @release_fixture["manifest"].deep_dup
    stable["channel"] = "stable"
    assert_raises(Railpress::Releases::Invalid) { Railpress::Releases::Manifest.validate!(stable) }
    stable["version"] = "2.0.0"
    assert_equal "stable", Railpress::Releases::Manifest.validate!(stable)["channel"]
    legacy = @release_fixture["manifest"].deep_dup
    legacy["version"], legacy["channel"] = "0.1.0-alpha.1", "development"
    legacy["files"].delete("lib/railpress/dusk.json")
    assert_equal "0.1.0-alpha.1", Railpress::Releases::Manifest.validate!(legacy)["version"]
    legacy["version"], legacy["channel"] = "2.0.0-alpha.1", "alpha"
    assert_raises(Railpress::Releases::Invalid) { Railpress::Releases::Manifest.validate!(legacy) }
  end
  test "checks are opt in cached signature verified offline safe and do not install" do
    assert_equal "DISABLED", Releases::Catalog.view["state"]
    assert_nil Releases::Catalog.refresh!(source: Object.new)
    refresh
    view = Releases::Catalog.view
    assert_equal "Railpress update available", view["notice"]
    assert view["compatible"]
    assert_equal "2.0.0-alpha.2", view["candidate"]["version"]
    assert_empty ReleaseRequest.all
    assert_equal @old_theme.id, ThemeState.first.active_installation_id
    Releases::Catalog.configure!(actor: @owner, enabled: true, channel: "alpha")
    unavailable = Object.new; unavailable.define_singleton_method(:releases) { raise "OFFLINE SECRET MUST NOT LEAK" }
    Releases::Catalog.refresh!(source: unavailable)
    assert_equal "STALE / UNKNOWN", Releases::Catalog.view["state"]
    assert_equal "2.0.0-alpha.2", Releases::Catalog.view["candidate"]["version"]
    refute_includes Releases::Catalog.payload("catalog").to_json, "OFFLINE SECRET"
    Releases::Catalog.configure!(actor: @owner, enabled: false, channel: "alpha")
    assert_equal "DISABLED", Releases::Catalog.view["state"]
    assert_empty Releases::Catalog.verified_items
    assert Releases::Catalog.payload("trust")["sequences"].any?, "Opt-out must not erase replay authority"
  end
  test "malicious signatures URL tag mismatch revoked publishers and replay never replace last good cache" do
    refresh
    good = Releases::Catalog.view["candidate"]["release_id"]
    @metadata["signature"]["signature"] = "bad"
    Releases::Catalog.configure!(actor: @owner, enabled: true, channel: "alpha")
    Releases::Catalog.refresh!(source: @source)
    assert_equal good, Releases::Catalog.view["candidate"]["release_id"]
    # The fixture signature object was not the retained deep JSON copy.
    @metadata["signature"] = @release_fixture["signature"] = signed(@metadata["manifest"], @release_signer)
    @metadata["version"] = "2.0.0-alpha.3"
    Releases::Catalog.configure!(actor: @owner, enabled: true, channel: "alpha")
    Releases::Catalog.refresh!(source: @source)
    assert_equal good, Releases::Catalog.view["candidate"]["release_id"]
    @trust["generation"] = 2; @trust["revoked"] = [ Railpress::Releases.key_id(@release_signer) ]; write_trust
    assert_nil Releases::Catalog.view["candidate"]
  end
  test "owner sees an accurate blocked state and no working looking combined action on an unqualified host" do
    refresh; sign_in
    get "/admin/updates"
    assert_response :ok
    assert_includes response.body, "Update blocked by host or backup requirements"
    assert_select 'input[type="submit"][value="Update Railpress and Theme"]', count: 0
    assert_includes response.body, "2.0.0-alpha.1"
    assert_includes response.body, "dusk 1.0.0"
    assert_includes response.body, "server's IP"
    assert_empty ReleaseRequest.all
    token = csrf_token_for(self, "/admin/updates")
    post "/admin/updates/combined", params: { authenticity_token: token, request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"] }
    assert_response :unprocessable_entity
    assert_empty ReleaseRequest.all
  end
  test "single owner selection is exact idempotent preview gated and stale theme configuration fails closed" do
    combined_host; refresh; sign_in
    get "/admin/updates"
    assert_select 'input[type="submit"][value="Update Railpress and Theme"]'
    id = SecureRandom.uuid; token = csrf_token_for(self, "/admin/updates")
    params = { authenticity_token: token, request_id: id, release_id: @release_fixture["release_id"] }
    post "/admin/updates/combined", params: params.except(:authenticity_token)
    assert_response :unprocessable_entity
    2.times { post "/admin/updates/combined", params: params; assert_response :see_other }
    assert_equal 1, ReleaseRequest.count
    request = ReleaseRequest.first; plan = Releases::Combined.selection(request)
    assert_equal @old_overlay.id, plan["old_overlay_id"]
    assert_nil plan["selected_theme_id"]
    state = ThemeState.first; state.touch
    assert_raises(Releases::Combined::Conflict) { Releases::Combined.validate!(request, plan) }
  end
  test "administrator editor and author cannot enable checks or queue combined execution" do
    %w[administrator editor author].each do |role|
      user = create_account(role, "updates-#{role}")
      sign_in(self, user)
      token = csrf_token_for(self, "/admin")
      post "/admin/updates/checks", params: { authenticity_token: token, enabled: "1", channel: "alpha" }
      assert_response :forbidden
      post "/admin/updates/combined", params: { authenticity_token: token, release_id: "a" * 64, request_id: SecureRandom.uuid }
      assert_response :forbidden
    end
    refute Releases::Catalog.settings["enabled"]
    assert_empty ReleaseRequest.all
  end
  test "release parser ignores main drafts unsigned archives and unexpected destinations" do
    client = Releases::GithubSource.new
    body = JSON.generate([ { "draft" => true, "tag_name" => "v2.0.0", "published_at" => Time.now.iso8601, "assets" => [] },
      { "draft" => false, "tag_name" => "main", "published_at" => Time.now.iso8601, "assets" => [] } ])
    client.define_singleton_method(:get) { |*args, **options| body }
    assert_empty client.releases
    unsafe = Releases::GithubSource.new(resolver: ->(_) { [ "127.0.0.1" ] })
    assert_raises(Releases::GithubSource::Failure) { unsafe.get(Releases::GithubSource::ENDPOINT, limit: 100) }
    assert_raises(Releases::GithubSource::Failure) { unsafe.get("http://api.github.com/", limit: 100) }
    assert_raises(Releases::GithubSource::Failure) { unsafe.get("https://evil.example.invalid/", limit: 100) }
  end

  test "cached download paths are revalidated and failed checks observe their short backoff" do
    refresh
    cache = Releases::Catalog.payload("catalog")
    cache["items"].first["package_url"] = "https://github.com/another/project/releases/download/v2.0.0-alpha.2/package.tar.gz"
    Releases::Catalog.save!("catalog", cache)
    assert_empty Releases::Catalog.verified_items
    Releases::Catalog.configure!(actor: @owner, enabled: true, channel: "alpha")
    calls = 0
    offline = Object.new
    offline.define_singleton_method(:releases) { calls += 1; raise "offline" }
    2.times { Releases::Catalog.refresh!(source: offline) }
    assert_equal 1, calls
    assert_equal 300, Releases::Catalog.payload("catalog")["next_check_ttl"]
  end

  test "switching to stable immediately excludes cached alpha metadata and old signed sequences cannot replace authority" do
    refresh
    Releases::Catalog.configure!(actor: @owner, enabled: true, channel: "stable")
    assert_empty Releases::Catalog.verified_items
    assert_nil Releases::Catalog.view["candidate"]
    Releases::Catalog.configure!(actor: @owner, enabled: true, channel: "alpha")
    assert_equal "2.0.0-alpha.2", Releases::Catalog.view["candidate"]["version"]
    @metadata["manifest"]["sequence"] = 2
    @metadata["signature"] = signed(@metadata["manifest"], @release_signer)
    Releases::Catalog.refresh!(source: @source)
    good = Releases::Catalog.view["candidate"]["release_id"]
    @metadata["manifest"]["sequence"] = 1
    @metadata["signature"] = signed(@metadata["manifest"], @release_signer)
    Releases::Catalog.configure!(actor: @owner, enabled: true, channel: "alpha")
    Releases::Catalog.refresh!(source: @source)
    assert_equal good, Releases::Catalog.view["candidate"]["release_id"]
    assert_equal 2, Releases::Catalog.payload("trust").dig("sequences", "alpha", "sequence")
    assert_equal "release_check_unavailable", Releases::Catalog.payload("catalog")["error"]
  end

  test "combined composition reports signed completion preserves overlays and refuses duplicate execution" do
    combined_host; refresh
    request = Releases::Combined.submit!(actor: @owner, release_id: @release_fixture["release_id"], request_id: SecureRandom.uuid)
    before = [ User.first.password_digest, Content.count, MediaAsset.count, ThemeState.first.active_overlay_id ]
    calls = 0
    host = Object.new
    result = { "format" => "railpress.host-result.v1", "deployment_id" => ENV["RAILPRESS_DEPLOYMENT_ID"],
      "scope" => "isolated-synthetic-nginx-v1", "request_id" => request.request_key, "operation" => "promote",
      "release_id" => request.release_digest, "revision" => 1, "generation" => 1, "state" => "ACTIVE", "error" => nil,
      "active_release" => request.release_digest, "publisher" => Railpress::Releases.key_id(@release_signer) }
    receipt = Railpress::NativeHost.sign(result, @status_signer)
    host.define_singleton_method(:perform) { |_| calls += 1; receipt }
    staged = Railpress::NativeHost.sign({ "state" => "STAGED", "error" => nil,
      "request_id" => request.request_key, "release_id" => request.release_digest }, @status_signer)
    staging = Object.new; staging.define_singleton_method(:stage) { |**_| staged }
    operator = Releases::CombinedOperator.new(staging: staging, host: host, prepare_stage: ->(*) { }, approve_promote: ->(*) { },
      signer: @status_signer, health: ->(_) { true }, lock_root: @operator_root)
    path = File.join(@operator_root, "combined-#{request.request_key}.lock")
    File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      assert_raises(Releases::Combined::Conflict) { operator.perform(request) }
    end
    assert_equal 0, calls
    assert_equal "COMPLETE", operator.perform(request)["state"]
    assert_equal "COMPLETE", operator.perform(request)["state"]
    assert_equal 1, calls
    assert_equal before, [ User.first.password_digest, Content.count, MediaAsset.count, ThemeState.first.active_overlay_id ]
    original = Releases::Combined.selection(request)["result"]
    operator.finish(request, Releases::Combined.selection(request), "CORE_UPDATE_FAILED", "late_error")
    assert_equal original, Releases::Combined.selection(request)["result"]
    refute Releases::Combined.result(request)["automatic_database_restore"]
  end

  test "failed staging cannot reach native promotion or alter the active theme" do
    combined_host; refresh
    request = Releases::Combined.submit!(actor: @owner, release_id: @release_fixture["release_id"], request_id: SecureRandom.uuid)
    before = ThemeState.first.attributes
    failed = Railpress::NativeHost.sign({ "state" => "FAILED_STAGED", "error" => "package_digest",
      "request_id" => request.request_key, "release_id" => request.release_digest }, @status_signer)
    staging = Object.new; staging.define_singleton_method(:stage) { |**_| failed }
    operator = Releases::CombinedOperator.new(staging: staging, host: Object.new, prepare_stage: ->(*) { },
      approve_promote: ->(*) { flunk "Promotion must not run" }, signer: @status_signer, health: ->(_) { flunk "No post-update health before staging" }, lock_root: @operator_root)
    assert_equal "FAILED_STAGED", operator.perform(request)["state"]
    assert_equal before, ThemeState.first.attributes
    assert_equal "FAILED_STAGED", Releases::Combined.result(request)["state"]
  end

  test "independent trusted staged theme updates are visible without a core release or remote lookup" do
    stage("dusk", version: "1.1.0")
    sign_in
    get "/admin/updates"
    assert_response :ok
    assert_includes response.body, "Theme update available."
    assert_includes response.body, "dusk 1.1.0"
    assert_includes response.body, "Requires Core Theme API 1"
    assert_includes response.body, "no remote third-party availability is inferred."
    refute Releases::Catalog.settings["enabled"]
    assert_empty ReleaseRequest.all
    assert_equal @old_theme.id, ThemeState.first.active_installation_id
  end
end
