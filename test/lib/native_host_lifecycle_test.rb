require "test_helper"
require_relative "../support/native_host_test_support"
require_relative "../support/release_test_support"
require_relative "../support/native_host_fake_runtime"

class NativeHostLifecycleTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include NativeHostTestSupport
  include ReleaseTestSupport
  class SimulatedTermination < Exception; end
  class ControlledClock
    attr_accessor :anomaly, :domain
    def initialize
      @domain = "controlled-native-domain"
    end
    def sample = { "elapsed" => 1000.0, "domain" => domain, "epoch" => "e" * 64, "anomaly" => anomaly }
  end
  setup do
    install_site!
    native_setup
    @operator_root = @native_root
    @release_now = Time.now
    @release_signer = OpenSSL::PKey.generate_key("ED25519")
    @time_signer = OpenSSL::PKey.generate_key("ED25519")
    @status_signer = @native_signer
    @keys = [ [ @release_signer, "release" ], [ @time_signer, "time" ], [ @status_signer, "status" ] ].to_h { |key, purpose|
      [ Railpress::Releases.key_id(key), { "purpose" => purpose, "public_key" => key.public_to_pem } ]
    }
    @trust = { "format" => "railpress.trust.v1", "generation" => 1, "keys" => @keys, "revoked" => [] }
    write_trust
    Railpress::NativeHost::F.atomic(@native_config.path("status.key"), @status_signer.private_to_pem)
    @theme_contract = [ { "id" => "dusk", "version" => "1.1.0", "digest" => "d" * 64 } ]
    @old = native_fixture("0.1.0-alpha.2", 1)
    @new = native_fixture("0.1.0-alpha.3", 2)
    native_plan(@old, [])
    native_plan(@new, [ @old["release_id"] ])
    fixtures = [ @old, @new ].to_h { |fixture| [ fixture["release_id"], fixture ] }
    @fake = NativeHostFakeRuntime.new(@native_config, fixtures, @theme_contract)
    @clock = ControlledClock.new
    @host = Railpress::NativeHost::Host.new(@native_config, clock: @clock, runtime: @fake)
    @host.store.transaction do |state|
      id = @old["release_id"]
      state["active"], state["previous"], state["contract"] = id, nil, { "schema" => 11, "write" => 11, "jobs" => 1, "theme_api" => 1 }
      state["releases"][id] = { "version" => @old["manifest"]["version"] }
      stage_id = SecureRandom.uuid
      state["sequence"] = { "development" => { "sequence" => 2, "release_id" => @new["release_id"], "request_id" => stage_id } }
      state["admitted"] = { id => { "sequence" => 1 }, @new["release_id"] => state["sequence"]["development"] }
      state["services"] = {}
      state["proxy"] = { "alive" => true }
      state["restore_proof"] = { "completed" => true, "deployment_id" => @native_document["deployment_id"], "environment_sha256" => @native_document["environment_sha256"] }
      @fake.prepare_tree!(id, @old["manifest"])
      @fake.seed!(state, id)
    end
  end
  teardown { native_teardown }

  def native_fixture(version, sequence)
    fixture = build_release(version: version, sequence: sequence)
    %w[schema_read schema_write].each { |key| fixture["manifest"]["compatibility"][key] = [ 11, 12 ] }
    fixture["manifest"]["compatibility"]["prior_versions"] = [ Railpress::Product::VERSION, "0.1.0-alpha.2", "0.1.0-alpha.3" ]
    fixture["release_id"] = Digest::SHA256.hexdigest(Railpress::Releases.canonical(fixture["manifest"]))
    fixture["signature"] = signed(fixture["manifest"], @release_signer)
    publish_fixture(fixture)
    fixture
  end
  def native_plan(fixture, predecessors)
    statement = { "format" => "railpress.native-plan.v1", "release_id" => fixture["release_id"], "predecessors" => predecessors,
      "expand" => nil, "contract" => { "schema" => 11, "write" => 11, "jobs" => 1, "theme_api" => 1 },
      "routes" => [ { "path" => "/", "status" => 200, "family" => "home" } ] }
    Railpress::NativeHost::F.atomic(@native_config.path("inbox", fixture["release_id"], "native-plan.json"),
      JSON.generate(Railpress::NativeHost.sign(statement, @release_signer)))
  end
  def approve(operation = "promote", fixture = @new)
    id = SecureRandom.uuid
    prepared = @host.approve!(operation: operation, id: id, release_id: fixture["release_id"], confirmation: @native_document["deployment_id"])
    statement = { "format" => "railpress.utc.v1", **prepared["challenge"], "utc" => @release_now.to_i }
    Railpress::NativeHost::F.atomic(@native_config.path("receipts", "#{id}.json"), JSON.generate(Railpress::NativeHost.sign(statement, @time_signer)))
    id
  end
  def perform(id)
    @host.define_singleton_method(:snapshot_ready!) { |_state, _policy| { "fixture" => "unit backup gate; real snapshots separately tested" } }
    @host.perform(id)
  ensure
    @host.singleton_class.remove_method(:snapshot_ready!) if @host.singleton_class.instance_methods(false).include?(:snapshot_ready!)
  end
  def state
    Railpress::NativeHost.load_document(@native_config.path("host-journal.json"), maximum: 2_097_152)
  end
  test "compatible promotion and code revert preserve clock and site without data rewind" do
    id = approve
    result = perform(id)
    assert_nil result.dig("statement", "error")
    assert_equal "ACTIVE", result.dig("statement", "state")
    assert_equal @new["release_id"], state["active"]
    assert_equal @new["release_id"], @fake.observed["release_id"]
    assert_equal @old["release_id"], state["previous"]
    assert_equal %w[PREFLIGHT STAGED SCHEMA_EXPANDED WARMED READY SWITCHING VERIFYING ACTIVE], state["events"].map { |row| row["phase"] }
    assert_equal result, perform(id)
    assert_equal 1, @fake.switches.length
    reverted = perform(approve("revert", @old))
    assert_nil reverted.dig("statement", "error")
    assert_equal "PREVIOUS_ACTIVE", reverted.dig("statement", "state")
    assert_equal @old["release_id"], state["active"]
    assert_equal 1, User.count
    assert_equal @owner.password_digest, User.first.password_digest
  end
  test "restore refusal before destructive intent preserves availability but pending restoration holds maintenance" do
    [ "snapshot_integrity", "snapshot_context", "snapshot_release_mismatch", "restore_password_verifiers_changed", "restore_loss_window_not_accepted" ].each do |code|
      @host.store.transaction do |row|
        request = @host.store.operation!(row, id: SecureRandom.uuid, operation: "restore", release_id: @old["release_id"])
        request["error"] = code
        @host.failure!(row, request)
        assert_equal "FAILED_STAGED", request["phase"]
        refute row["maintenance"]
        refute row["recovery_required"]
        assert_equal @old["release_id"], row["active"]
      end
    end
    @host.store.transaction do |row|
      row["restore_pending"] = { "snapshot_id" => SecureRandom.uuid }
      request = @host.store.operation!(row, id: SecureRandom.uuid, operation: "restore", release_id: @old["release_id"])
      request["error"] = "snapshot_integrity"
      @host.failure!(row, request)
      assert_equal "RESTORE_REQUIRED", request["phase"]
      assert row["maintenance"]
      assert row["recovery_required"]
    end
  end
  test "dry run leaves every native file unchanged and does not call proxy" do
    id = approve
    before = Dir.glob(@native_config.path("**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }.to_h { |p| [ p, Digest::SHA256.file(p).hexdigest ] }
    report = @host.dry_run(id)
    after = before.keys.to_h { |p| [ p, Digest::SHA256.file(p).hexdigest ] }
    assert_equal before, after
    assert report["dry_run"]
    refute report["mutations_performed"]
    assert_empty @fake.switches
  end
  test "known clock fault while warming never switches public traffic" do
    id = approve
    @host = Railpress::NativeHost::Host.new(@native_config, clock: @clock, runtime: @fake, fault: ->(point) {
      @clock.anomaly = { "controlled" => true } if point == "WARMED"
    })
    result = perform(id)
    assert_equal "clock_anomaly", result.dig("statement", "error")
    assert_equal "FAILED_STAGED", result.dig("statement", "state")
    assert_equal @old["release_id"], state["active"]
    assert_empty @fake.switches
  end
  test "operator termination after simulated switch boundary reconciles observed target exactly once" do
    id = approve
    @host = Railpress::NativeHost::Host.new(@native_config, clock: @clock, runtime: @fake, fault: ->(point) {
      raise SimulatedTermination if point == "after_proxy_switch"
    })
    assert_raises(SimulatedTermination) { perform(id) }
    assert_equal "SWITCHING", state["operations"][id]["phase"]
    assert_equal @old["release_id"], state["active"]
    assert_equal @new["release_id"], @fake.observed["release_id"]
    @host = Railpress::NativeHost::Host.new(@native_config, clock: @clock, runtime: @fake)
    result = perform(id)
    assert_nil result.dig("statement", "error")
    assert_equal @new["release_id"], state["active"]
    assert_equal 1, @fake.switches.length
  end
  test "two approvals cannot both overwrite the same expected host generation" do
    first, stale = approve, approve
    assert_nil perform(first).dig("statement", "error")
    result = perform(stale)
    assert result.dig("statement", "error")
    assert_equal @new["release_id"], state["active"]
    assert_equal 1, @fake.switches.length
  end
  test "missing native approval or actual restore drill refuses new activation" do
    id = approve
    @host.store.transaction { |document| document["operations"][id]["native_approved"] = false }
    result = perform(id)
    assert_equal "native_approval_required", result.dig("statement", "error")
    assert_equal @old["release_id"], state["active"]
    id = approve
    @host.store.transaction { |document| document["restore_proof"] = nil }
    result = @host.perform(id)
    assert_equal "restore_drill_unqualified", result.dig("statement", "error")
    assert_empty @fake.switches
  end
  test "native approval pins the signed plan so another trusted plan cannot replace it mid operation" do
    id = approve
    path = @native_config.path("inbox", @new["release_id"], "native-plan.json")
    envelope = Railpress::NativeHost.load_document(path)
    envelope["statement"]["routes"][0]["path"] = "/changed-after-approval"
    Railpress::NativeHost::F.atomic(path, JSON.generate(Railpress::NativeHost.sign(envelope["statement"], @release_signer)))
    result = perform(id)["statement"]
    assert_equal "native_plan_changed", result["error"]
    assert_equal @old["release_id"], state["active"]
    assert_empty @fake.switches
    assert_equal @theme_contract.first, @fake.health["theme"]
  end
  test "unstaged new metadata cannot be promoted even with separate native approval" do
    @host.store.transaction { |row| row["admitted"].delete(@new["release_id"]) }
    id = approve
    result = perform(id)["statement"]
    assert_equal "verified_stage_required", result["error"]
    assert_empty @fake.switches
    assert_equal @old["release_id"], state["active"]
  end
  test "worker failure before cutover restores the prior worker without changing public code" do
    original = @fake.method(:worker!)
    target = @new["release_id"]
    @fake.define_singleton_method(:worker!) do |row, release, slot|
      raise Railpress::NativeHost::Error, "injected_worker_failure" if release == target
      original.call(row, release, slot)
    end
    result = perform(approve)["statement"]
    assert_equal "injected_worker_failure", result["error"]
    assert_equal @old["release_id"], state["active"]
    assert_empty @fake.switches
    assert @fake.verified(state["services"][@old["release_id"]]["worker"])
    assert_equal @theme_contract.first, @fake.health["theme"]
  end
  test "signed status refuses to describe a generation mismatch as healthy" do
    @fake.observed["generation"] += 1
    status = @host.status
    assert status["reconciliation_required"]
    refute status["services_healthy"]
    @host.store.transaction { |row| @host.publish!(row) }
    published = Railpress::NativeHost.load_document(@native_config.app_environment["RAILPRESS_NATIVE_PUBLIC_STATUS"])["statement"]
    assert published["reconciliation_required"]
    refute_includes published["capabilities"], "promote"
    refute_includes published["capabilities"], "revert"
  end
  test "native CLI rejects arbitrary operations paths and restore commands without explicit loss review" do
    [
      [ "promote", ";touch" ],
      [ "authorize", "shell", SecureRandom.uuid, "a" * 64, "--confirm-deployment", SecureRandom.uuid ],
      [ "status", "--root", "/etc" ],
      [ "restore", SecureRandom.uuid, "--snapshot", SecureRandom.uuid ],
      [ "authorize", "restore", SecureRandom.uuid, "a" * 64, "--confirm-deployment", SecureRandom.uuid ],
      [ "stage", SecureRandom.uuid, "--dry-run" ],
      [ "supervise", "--shell" ]
    ].each { |argv| assert_raises(Railpress::NativeHost::Error) { Railpress::NativeHost::Cli.parse(argv) } }
    assert_equal({ command: "supervise", once: true }, Railpress::NativeHost::Cli.parse([ "supervise", "--once" ]))
    assert_equal @old["release_id"], state["active"]
  end
  def guarded_restore_probe(preflight_error: nil, pending: false)
    metadata = { "snapshot_id" => SecureRandom.uuid, "active_release" => @old["release_id"],
      "contract" => { "schema" => 11, "write" => 11, "jobs" => 1, "theme_api" => 1 } }
    invoked = false
    double = Object.new
    double.define_singleton_method(:validate!) { |*_, **_| metadata }
    double.define_singleton_method(:preflight!) do |_point, **_|
      raise Railpress::NativeHost::Error, preflight_error if preflight_error
      {}
    end
    double.define_singleton_method(:restore!) { |**_| invoked = true; raise "unexpected SQL restore" }
    @fake.define_singleton_method(:stop_all_apps!) do |row|
      row["services"].keys.each { |id| stop_worker!(row, id); stop_puma!(row, id) }
    end
    @host.store.transaction do |row|
      request = @host.store.operation!(row, id: SecureRandom.uuid, operation: "restore", release_id: @old["release_id"])
      request.merge!("snapshot_id" => metadata["snapshot_id"], "accepted_loss_fingerprint" => "a" * 64)
      if pending
        row["restore_pending"] = { "snapshot_id" => metadata["snapshot_id"], "release_id" => @old["release_id"],
          "accepted_loss_fingerprint" => "a" * 64, "started_elapsed" => Railpress::SecurityClock.elapsed }
      end
      error = assert_raises(Railpress::NativeHost::Error) do
        with_native_method(Railpress::NativeHost::Snapshot, :new, proc { |*_, **_| double }) do
          @host.restore!(row, request, @old["manifest"], {}, @host.trust)
        end
      end
      assert_equal "legacy_in_place_restore_unsupported", error.message
      refute invoked
      assert_equal @old["release_id"], row["active"]
      assert_equal 0, row["generation"]
      assert_equal pending, !!row["restore_pending"]
      refute row["maintenance"]
      assert @fake.verified(row["services"][@old["release_id"]]["puma"])
    end
    assert_empty @fake.switches
  end

  test "restore resource refusal happens before destructive pending intent and keeps old service" do
    guarded_restore_probe(preflight_error: "disk_capacity")
  end

  test "unsupported restore preserves pending context without stopping tracked services" do
    guarded_restore_probe(pending: true)
  end
  test "perform refuses unsupported restore before reconciliation and leaves journal and services intact" do
    id = SecureRandom.uuid
    @host.store.transaction { |row| @host.store.operation!(row, id: id, operation: "restore", release_id: @old["release_id"]) }
    before = File.binread(@native_config.path("host-journal.json"))
    original = @fake.method(:recover_services!)
    @fake.define_singleton_method(:recover_services!) { |_row| raise "unsupported restore reached service reconciliation" }
    error = assert_raises(Railpress::NativeHost::Error) { @host.perform(id) }
    assert_equal "legacy_in_place_restore_unsupported", error.message
    assert_equal before, File.binread(@native_config.path("host-journal.json"))
    assert_empty @fake.switches
  ensure
    @fake.define_singleton_method(:recover_services!, original) if original
  end
end
