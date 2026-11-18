require "test_helper"
require_relative "../support/native_host_test_support"

class NativeHostPrimitivesTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include NativeHostTestSupport
  setup do
    install_site!
    native_setup
  end
  teardown do
    native_teardown
  end

  test "native configuration proves exact synthetic instance and keeps host authority out of app environment" do
    target, identity = @native_config.database!
    assert_equal ENV["RAILPRESS_TEST_ENGINE"], target["adapter"]
    assert_equal @native_document["database_instance_id"], identity["instance_id"]
    id = "a" * 64
    Dir.mkdir(@native_config.path("releases", id), 0o700)
    runtime = @native_config.runtime_environment(id, slot: 1)
    assert_equal "59111", runtime["PORT"]
    assert_equal id, runtime["RAILPRESS_DEPLOYMENT_DIGEST"]
    refute runtime.key?("RAILPRESS_RELEASE_OPERATOR_ROOT")
    refute runtime.key?("RAILPRESS_NATIVE_HOST_ROOT")
    assert_equal @native_env["SECRET_KEY_BASE"], runtime["SECRET_KEY_BASE"]
  end
  test "host refuses production profile remote origin swapped environment and unknown commands" do
    original = @native_document.dup
    %w[production remote-linux unknown].each do |scope|
      @native_document["scope"] = scope
      native_write_config
      assert_raises(Railpress::NativeHost::Error) { Railpress::NativeHost::Config.new(@native_root) }
    end
    @native_document = original
    native_write_config
    File.write(@native_config.path("shared/environment.json"), "{}")
    assert_raises(Railpress::NativeHost::Error) { Railpress::NativeHost::Config.new(@native_root) }
    assert_raises(Railpress::NativeHost::Error) { Railpress::NativeHost.uuid!(";echo unsafe") }
  end
  test "native journal persists idempotency and refuses conflicting operation identity" do
    store = Railpress::NativeHost::State.new(@native_config)
    id = SecureRandom.uuid
    store.transaction do |state|
      request = store.operation!(state, id: id, operation: "preflight", release_id: "a" * 64)
      store.transition!(state, request, "READY")
    end
    store.transaction do |state|
      request = store.operation!(state, id: id, operation: "preflight", release_id: "a" * 64)
      assert_equal "READY", request["phase"]
      assert_equal 1, request["revision"]
      assert_raises(Railpress::NativeHost::Error) { store.operation!(state, id: id, operation: "revert", release_id: "b" * 64) }
    end
    File.unlink(@native_config.path("host-journal.json"))
    assert_raises(Railpress::NativeHost::Error) { store.transaction { flunk } }
  end
  test "native database commands use only admitted credentials and suppress ambient MySQL login paths" do
    credential_file = nil
    @native_db.client_credentials(SecureRandom.uuid) do |target, environment, arguments|
      refute environment.key?("HOME")
      refute environment.key?("MYSQL_HOME")
      if target["adapter"] == "mysql2"
        assert_match(/\A--defaults-file=/, arguments.first)
        assert_includes arguments, "--no-login-paths"
        refute arguments.any? { |value| value.start_with?("--defaults-extra-file=") }
        credential_file = arguments.first.delete_prefix("--defaults-file=")
        assert_equal 0, File.stat(credential_file).mode & 0o077
        assert_includes File.read(credential_file), "protocol=TCP\n"
      else
        credential_file = environment.fetch("PGPASSFILE")
        assert_equal "disable", environment["PGSSLMODE"]
        assert_equal 0, File.stat(credential_file).mode & 0o077
      end
    end
    refute File.exist?(credential_file), "temporary credential file must be removed"
  end
  test "snapshot really dumps the selected engine and detects corruption before restoration" do
    metadata = snapshot_create
    id = metadata["snapshot_id"]
    assert_equal @native_document["engine"], metadata["engine"]
    assert_equal metadata, snapshot_validate(id)
    assert File.size(@native_config.path("snapshots", id, "database.dump")).positive?
    File.open(@native_config.path("snapshots", id, "database.dump"), "ab") { |file| file.write("tampered") }
    assert_raises(Railpress::NativeHost::Error) { snapshot_validate(id) }
    assert_equal @owner.id, Site.first.owner_id
  end
  test "missing media symlink and incomplete backup cannot claim a recovery point" do
    File.write(@native_config.path("shared/media/asset"), "synthetic pixels")
    metadata = snapshot_create
    File.unlink(@native_config.path("snapshots", metadata["snapshot_id"], "shared/media/asset"))
    assert_raises(Railpress::NativeHost::Error) { snapshot_validate(metadata["snapshot_id"]) }
    File.symlink("/etc/passwd", @native_config.path("shared/media/escape"))
    assert_raises(Railpress::NativeHost::Error) { snapshot_create }
    File.unlink(@native_config.path("shared/media/escape"))
    assert_equal 1, Site.count
  end
  test "unsupported restore discards only approved synthetic later writes and revokes restored credential families refuses without mutation" do
    token = UserSession.issue!(@owner)
    metadata = snapshot_create
    File.write(@native_config.path("shared/media/later"), "retained later media")
    before = @native_db.integrity.capture
    [ false, true ].each do |resume|
      error = assert_raises(Railpress::NativeHost::Error) do
        @snapshot.restore!(operation_id: SecureRandom.uuid, metadata: metadata, resume: resume)
      end
      assert_equal "legacy_in_place_restore_unsupported", error.message
    end
    assert_equal before, @native_db.integrity.capture
    assert UserSession.resolve(token)
    assert_equal "retained later media", File.read(@native_config.path("shared/media/later"))
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end

  test "unsupported restore revokes preview media references before previews and preserves permanent references refuses without mutation" do
    token = UserSession.issue!(@owner)
    metadata = snapshot_create
    File.write(@native_config.path("shared/media/later"), "retained later media")
    before = @native_db.integrity.capture
    [ false, true ].each do |resume|
      error = assert_raises(Railpress::NativeHost::Error) do
        @snapshot.restore!(operation_id: SecureRandom.uuid, metadata: metadata, resume: resume)
      end
      assert_equal "legacy_in_place_restore_unsupported", error.message
    end
    assert_equal before, @native_db.integrity.capture
    assert UserSession.resolve(token)
    assert_equal "retained later media", File.read(@native_config.path("shared/media/later"))
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end

  test "snapshot trust context and signature are bound to the original installation" do
    metadata = snapshot_create
    file = @native_config.path("snapshots", metadata["snapshot_id"], "snapshot.json")
    envelope = Railpress::NativeHost.load_document(file)
    envelope["statement"]["installation_id"] = SecureRandom.uuid
    Railpress::NativeHost::F.atomic(file, JSON.generate(envelope))
    assert_raises(Railpress::NativeHost::Error) { snapshot_validate(metadata["snapshot_id"]) }
  end
  test "an interrupted real unsupported restore resumes only the same context and retains failed media copies refuses without mutation" do
    token = UserSession.issue!(@owner)
    metadata = snapshot_create
    File.write(@native_config.path("shared/media/later"), "retained later media")
    before = @native_db.integrity.capture
    [ false, true ].each do |resume|
      error = assert_raises(Railpress::NativeHost::Error) do
        @snapshot.restore!(operation_id: SecureRandom.uuid, metadata: metadata, resume: resume)
      end
      assert_equal "legacy_in_place_restore_unsupported", error.message
    end
    assert_equal before, @native_db.integrity.capture
    assert UserSession.resolve(token)
    assert_equal "retained later media", File.read(@native_config.path("shared/media/later"))
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end

  test "proxy pins canonical forwarded host port and rejects unknown host instead of trusting user headers" do
    bytes = Railpress::NativeHost::Proxy.new(@native_config, Railpress::NativeHost::Processes.new(@native_config)).config_bytes(id: "a" * 64, slot: 0, generation: 0)
    assert_includes bytes, "proxy_set_header X-Forwarded-Host localhost:#{@native_document['edge_port']};"
    assert_includes bytes, "if ($host != localhost) { return 421; }"
    assert_includes bytes, "proxy_set_header X-Forwarded-For $remote_addr;"
    assert_includes bytes, 'proxy_set_header Forwarded "";'
    refute_includes bytes, "$http_x_forwarded_host"
  end
end
