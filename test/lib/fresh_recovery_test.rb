require "test_helper"
require "railpress/recovery"
require_relative "../support/gcs_test_support"
require_relative "../support/native_host_test_support"

class FreshRecoveryTest < ActiveSupport::TestCase
  include GcsTestSupport
  include NativeHostTestSupport
  setup { native_setup }
  teardown { native_teardown }
  test "bounded authenticated manifest and read-only validator cover complete SQL and retained media" do
    @service.instance_variable_set(:@store, Railpress::Gcs::Store.new(bucket: "synthetic-bucket", project: "synthetic-project", prefix: "r8/recovery", client: @api))
    asset = upload_media
    post = draft(blocks: [ { "type" => "image", "media_id" => asset.id } ])
    change(post, "publish")
    config = @native_config.path("shared", "application-secrets.json")
    Railpress::NativeHost::F.atomic(config, JSON.generate("SECRET_KEY_BASE" => SecureRandom.hex(64)))
    files = { "application_secrets" => config }
    dump = @native_config.path("snapshots", "fresh.dump")
    path = @native_config.path("snapshots", "fresh.json")
    ActiveRecord::Base.connection_handler.clear_all_connections!
    point = Railpress::Recovery::Manifest.capture!(database: @native_db, dump: dump, output: path,
      app_root: Rails.root.to_s, configuration_files: files, theme_root: @native_config.path("shared", "themes"),
      clock: Railpress::SecurityClock.new(@private_root), freeze_confirmed: "writers-stopped-no-ddl")
    digest = Digest::SHA256.file(path).hexdigest
    assert_equal point, Railpress::Recovery::Manifest.load(path, trusted_sha256: digest)
    assert_raises(Railpress::Recovery::Error) { Railpress::Recovery::Manifest.load(path, trusted_sha256: "0" * 64) }
    assert_equal 2, point["media"].length
    assert point["media"].all? { |binding| binding["prefix"] == "r8/recovery" }
    refute_includes File.read(path), JSON.parse(File.read(config))["SECRET_KEY_BASE"]
    refute File.read(path).include?(Railpress::SecurityClock.new(@private_root).sample["epoch"]), "Manifest must exclude private clock authority"
    build = ->(manifest = point) { Railpress::Recovery::Validator.new(manifest: manifest, dump: dump, app_root: Rails.root.to_s,
      configuration_files: files, theme_root: @native_config.path("shared", "themes"), store: @service.store) }
    before_db = @native_db.integrity.capture
    before_objects = @api.fingerprint
    report = build.call.run(database: @native_db)
    assert_equal "VERIFIED", report["status"], report.inspect
    assert_equal "NOT ATTESTED", report["provider_qualification"]
    assert_equal "NOT TESTED", report["application_http"]
    reused = build.call
    assert_equal "UNKNOWN", reused.run["checks"]["restored_database"]
    assert_equal "VERIFIED", reused.run(database: @native_db)["status"]
    refute reused.checks.key?("restored_database")
    assert_equal before_objects, @api.fingerprint
    assert @native_db.integrity.verify!(before_db)
    broken = Marshal.load(Marshal.dump(point))
    broken.delete("security")
    assert_equal "UNSUPPORTED", build.call(broken).run["checks"]["manifest"]
    broken = Marshal.load(Marshal.dump(point))
    broken["media"][0]["generation"] = "9999"
    assert_equal "MISMATCH", build.call(broken).run["checks"]["media_0"]
    missing = @api.objects.delete(@service.store.object_name(point["media"][0]["key"]))
    assert_equal "MISSING", build.call.run["checks"]["media_0"]
    @api.objects[@service.store.object_name(point["media"][0]["key"])] = missing
    @api.failure = Google::Cloud::PermissionDeniedError.new("synthetic credential never log")
    assert_equal "INACCESSIBLE", build.call.run["checks"]["media_0"]
    @api.failure = nil
    File.open(dump, "ab") { |io| io.write("corrupt") }
    assert_equal "MISMATCH", build.call.run["checks"]["dump"]
    assert_equal before_objects, @api.fingerprint
    assert @native_db.integrity.verify!(before_db)
  end
  test "fresh admission refuses populated schema and unknown profile before any native load" do
    common = { registry_root: Rails.root.to_s, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), db_tools: @native_config.data["db_tools"], install_id: Site.first.install_id }
    parent = Rails.root.join(".local/state/gcs-recovery")
    FileUtils.mkdir_p(parent, mode: 0o700)
    root = Dir.mktmpdir("admission-", parent)
    begin
      assert_raises(Railpress::Recovery::Error) { Railpress::Recovery::Target.new(**common, profile: "default", root: root) }
      ActiveRecord::Base.connection_handler.clear_all_connections!
      assert_raises(Railpress::Recovery::Error) { Railpress::Recovery::Target.assert_empty!(@native_db, common[:engine]) }
      assert_empty Dir.glob(File.join(root, "logs", "restore-*"))
    ensure
      FileUtils.remove_entry_secure(root)
    end
  end
  test "isolated production Rails candidate probe checks identity auth denial and scheduling hold without cloud access" do
    root = @native_config.path("shared", "candidate-test")
    Dir.mkdir(root, 0o700)
    Railpress::NativeHost::F.atomic(File.join(root, "setup.json"), JSON.generate(version: 1, status: "installed", install_id: Site.first.install_id))
    config = @native_config.path("shared", "application-secrets.json")
    Railpress::NativeHost::F.atomic(config, JSON.generate("SECRET_KEY_BASE" => SecureRandom.hex(64)))
    before = @native_db.integrity.capture
    ActiveRecord::Base.connection_handler.clear_all_connections!
    result = Railpress::Recovery::Candidate.check!(target: @native_config, app_root: Rails.root.to_s, clock_root: root,
      configuration_files: { "application_secrets" => config })
    assert_equal "VERIFIED", result["status"]
    assert_equal "NOT INVOKED", result["media_network"]
    assert_equal 303, result["rack_routes"]["/admin"]
    assert @native_db.integrity.verify!(before)
  end
  test "changed staff roles members and linked authority refuse restoration before loading" do
    point = @native_db.integrity.capture
    assert Railpress::Recovery::Fresh.authority_unchanged!(point, point)
    Identity::ManageUsers.change_role!(actor: @owner, user: @author, role: "editor")
    current = @native_db.integrity.capture
    assert_raises(Railpress::Recovery::Error) { Railpress::Recovery::Fresh.authority_unchanged!(current, point) }
    member = Member.create!(site: Site.first, public_id: SecureRandom.uuid)
    next_state = @native_db.integrity.capture
    assert_raises(Railpress::Recovery::Error) { Railpress::Recovery::Fresh.authority_unchanged!(next_state, current) }
    identity = MemberIdentity.create!(member: member, provider: "discord", subject: "123456789012345678")
    linked = @native_db.integrity.capture
    assert_raises(Railpress::Recovery::Error) { Railpress::Recovery::Fresh.authority_unchanged!(linked, next_state) }
    identity.destroy!
  end
end
