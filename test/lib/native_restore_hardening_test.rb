require "test_helper"
require_relative "../support/native_host_test_support"

class NativeRestoreHardeningTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include NativeHostTestSupport
  setup do
    install_site!
    native_setup
  end
  teardown { native_teardown }

  def point
    @member = Member.create!(site: Site.first, public_id: SecureRandom.uuid)
    UserSession.issue!(@owner)
    @metadata = snapshot_create
    @operation = SecureRandom.uuid
  end
  def restore(snapshot = @snapshot, resume: false)
    snapshot.restore!(operation_id: @operation, metadata: snapshot_validate(@metadata["snapshot_id"]), resume: resume)
  end
  def journal_path = @native_config.path("run", "pre-restore-#{@operation}", "verification.json")
  def journal = Railpress::NativeHost.load_document(journal_path, maximum: 65_536)
  test "unsupported replay refuses before verification connection fault or SQL" do
    point
    fired = false
    snapshot = Railpress::NativeHost::Snapshot.new(@native_config, signer: @native_signer, fault: ->(_phase) { fired = true; raise Errno::ENOSPC })
    before = @native_db.integrity.capture
    error = assert_raises(Railpress::NativeHost::Error) { restore(snapshot, resume: true) }
    assert_equal "legacy_in_place_restore_unsupported", error.message
    refute fired
    refute File.exist?(journal_path)
    assert_equal before, @native_db.integrity.capture
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end

  test "space refusal precedes restore intent SQL and retained context" do
    point
    before = @native_db.integrity.capture
    original = Railpress::NativeHost::F.method(:capacity!)
    calls = []
    shared = @native_config.path("shared")
    callback = ->(path, required) do
      calls << [ path, required ]
      raise Railpress::NativeHost::Error, "disk_capacity" if path == shared
      original.call(path, required)
    end
    error = assert_raises(Railpress::NativeHost::Error) do
      with_native_method(Railpress::NativeHost::F, :capacity!, callback) { @snapshot.preflight!(@metadata) }
    end
    assert_equal "disk_capacity", error.message
    assert_equal before, @native_db.integrity.capture
    assert_equal @native_config.path("shared"), calls.first.first
    assert_operator calls.first.last, :>=, 1024**3
    refute File.exist?(File.dirname(journal_path))
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end

  test "unsupported replay refuses before media ENOSPC fault or SQL" do
    point
    fired = false
    snapshot = Railpress::NativeHost::Snapshot.new(@native_config, signer: @native_signer, fault: ->(_phase) { fired = true; raise Errno::ENOSPC })
    before = @native_db.integrity.capture
    error = assert_raises(Railpress::NativeHost::Error) { restore(snapshot, resume: true) }
    assert_equal "legacy_in_place_restore_unsupported", error.message
    refute fired
    refute File.exist?(journal_path)
    assert_equal before, @native_db.integrity.capture
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end

  test "restore admission measures database and both storage paths with conservative journal reserve" do
    point
    report = @snapshot.preflight!(@metadata)
    assert_equal "bounded-synthetic-estimate-v1", report["model"]
    refute report["space_reserved"]
    assert_operator report["required_free_bytes"], :>, report["database_allocated_bytes"]
    %w[shared database].each { |name| assert_operator report["available_bytes"][name], :>=, report["required_free_bytes"] }
    if File.directory?("/mnt/c")
      assert_operator report["available_bytes"]["host"], :>=, report["required_free_bytes"] + 8 * 1024**3
    end
    refute File.exist?(@native_config.path("run", "mysql-restore-unsafe.json"))
  end

  test "resume with another target digest refuses without rewriting prior failure" do
    _target, identity = @native_config.database!
    path = @native_config.path("run", "journal-test.json")
    context = { "operation_id" => SecureRandom.uuid, "snapshot_id" => SecureRandom.uuid, "deployment_id" => @native_document["deployment_id"] }
    first = Railpress::NativeHost::RestoreJournal.new(path, context, identity, {})
    first.advance!("VERIFY_SCHEMA")
    first.fail!(Railpress::NativeHost::Error.new("injected_restore_interruption"))
    bytes = File.binread(path)
    assert_raises(Railpress::NativeHost::Error) do
      Railpress::NativeHost::RestoreJournal.new(path, context, identity.merge("database" => "other"), {})
    end
    assert_equal bytes, File.binread(path)
    refute File.exist?(@native_config.path("run", "verification-attempt-1.json"))
  end

  test "unknown connected writer is not killed or silently accepted" do
    @native_db.connection do |writer, engine|
      id = engine == "postgresql" ? writer.exec("SELECT pg_backend_pid() AS id").first["id"].to_i : writer.query("SELECT CONNECTION_ID() AS id").first["id"]
      error = assert_raises(Railpress::NativeHost::Error) { @native_db.assert_restore_offline! }
      assert_equal "restore_target_connected", error.message
      actual = engine == "postgresql" ? writer.exec("SELECT pg_backend_pid() AS id").first["id"].to_i : writer.query("SELECT CONNECTION_ID() AS id").first["id"]
      assert_equal id, actual
    end
  end

  test "untracked queue registration is refused before SQL even if its PID is not owned" do
    process = SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: 99999999,
      hostname: "synthetic-r4", last_heartbeat_at: Time.current)
    error = assert_raises(Railpress::NativeHost::Error) { @native_db.assert_restore_offline! }
    assert_equal "unverified_worker_registration", error.message
    assert SolidQueue::Process.exists?(process.id)
  ensure
    process&.destroy!
  end
  test "missing current root without exact retained operation context refuses before SQL" do
    point
    File.rename(@native_config.path("shared", "themes"), @native_config.path("run", "unbound-themes"))
    error = assert_raises(Railpress::NativeHost::Error) do
      @snapshot.preflight!(@metadata, operation_id: @operation, resume: true)
    end
    assert_equal "directory_unavailable", error.message
    refute File.exist?(File.dirname(journal_path))
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end
  test "database replay API refuses populated targets without launching a command" do
    point
    before = @native_db.integrity.capture
    error = assert_raises(Railpress::NativeHost::Error) { @native_db.restore!("a", "b", expected_tables: [], resume: true) }
    assert_equal "legacy_in_place_restore_unsupported", error.message
    ActiveRecord::Base.connection_handler.clear_all_connections!
    error = assert_raises(Railpress::NativeHost::Error) { @native_db.restore_fresh!("a", "b", expected_tables: []) }
    assert_equal "fresh_target_populated", error.message
    assert_equal before, @native_db.integrity.capture
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end
  test "independent failure journal retains phase and sanitizes connection and disk errors" do
    _target, identity = @native_config.database!
    [ Errno::ENOSPC.new("PRIVATE SQL"), StandardError.new("PRIVATE SQL") ].each_with_index do |error, index|
      path = @native_config.path("run", "failure-#{index}.json")
      context = { "operation_id" => SecureRandom.uuid, "snapshot_id" => SecureRandom.uuid, "deployment_id" => @native_document["deployment_id"] }
      journal = Railpress::NativeHost::RestoreJournal.new(path, context, identity, {})
      journal.advance!("VERIFY_INSTALLATION")
      journal.fail!(error)
      document = Railpress::NativeHost.load_document(path)
      assert_equal "FAILED", document["state"]
      assert_equal "VERIFY_INSTALLATION", document["phase"]
      assert_equal error.class.name, document["error_class"]
      refute File.read(path).include?("PRIVATE SQL")
      refute document.key?("error_message")
      refute document.key?("backtrace")
    end
  end
end
