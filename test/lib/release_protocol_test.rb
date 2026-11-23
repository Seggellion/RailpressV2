require "test_helper"
require_relative "../support/release_test_support"

class ReleaseProtocolTest < ActiveSupport::TestCase
  include ReleaseTestSupport
  setup { release_setup }
  teardown { release_teardown }

  test "deterministic native bundle and signed manifest stage without changing running product" do
    original_mask = File.umask(0o077)
    second = build_release
    assert_equal @release_fixture, second
    receipt = stage_release
    assert_nil receipt["statement"]["error"]
    assert_equal "STAGED", receipt["statement"]["state"]
    assert_equal Railpress::Product::VERSION, @operator.status["installed"]["version"]
    assert_equal false, @operator.status["active_switch_supported"]
    assert Railpress::Releases::Bundle.verify_tree!(File.join(@operator_root, "staging", @release_fixture["release_id"]), @release_fixture["manifest"])
  ensure
    File.umask(original_mask) if original_mask
  end

  test "native process restart and same request retry are idempotent" do
    id = SecureRandom.uuid
    assert_equal "STAGED", stage_release(id)["statement"]["state"]
    operator = new_operator
    assert_equal "STAGED", operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["state"]
    assert_equal 1, Dir.children(File.join(@operator_root, "staging")).length
    assert_equal 1, operator.status["history"].count { |event| event["state"] == "STAGED" }
  end

  test "unknown signatures changed metadata and corrupt packages are refused" do
    path = publish_fixture(@release_fixture)
    unknown = OpenSSL::PKey.generate_key("ED25519")
    Railpress::Releases::Filesystem.atomic(File.join(path, "signature.json"), JSON.generate(signed(@release_fixture["manifest"], unknown)))
    receipt = @operator.inspect(request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"])
    assert_equal "unknown_publisher", receipt["statement"]["error"]
    publish_fixture(@release_fixture)
    prepare_release(id = SecureRandom.uuid)
    File.binwrite(File.join(path, "package.tar.gz"), "corrupted")
    receipt = @operator.stage(request_id: id, release_id: @release_fixture["release_id"])
    assert_equal "package_digest", receipt["statement"]["error"]
    assert_empty Dir.children(File.join(@operator_root, "staging"))
    publish_fixture(@release_fixture)
    manifest = @release_fixture["manifest"].merge("changelog" => "Unsigned change")
    File.write(File.join(path, "manifest.json"), JSON.generate(manifest))
    assert_equal "manifest_identity", @operator.inspect(request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"])["statement"]["error"]
  end

  test "revocation survives policy rollback and publisher rotation is explicit" do
    @trust["generation"] = 2
    @trust["revoked"] = [ Railpress::Releases.key_id(@release_signer) ]
    write_trust
    assert_equal "revoked_publisher", @operator.inspect(request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"])["statement"]["error"]
    @trust["generation"] = 1
    @trust["revoked"] = []
    write_trust
    assert_equal "trust_rollback", @operator.inspect(request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"])["statement"]["error"]
    @trust["generation"] = 3
    @release_signer = OpenSSL::PKey.generate_key("ED25519")
    @trust["keys"][Railpress::Releases.key_id(@release_signer)] = { "purpose" => "release", "public_key" => @release_signer.public_to_pem }
    write_trust
    @release_fixture = build_release
    publish_fixture(@release_fixture)
    assert_equal "STAGED", stage_release["statement"]["state"]
  end

  test "sequence replay across different requests and process restarts is refused" do
    assert_equal "STAGED", stage_release["statement"]["state"]
    @operator = new_operator
    id = SecureRandom.uuid
    prepare_release(id)
    receipt = @operator.stage(request_id: id, release_id: @release_fixture["release_id"])
    assert_equal "manifest_replay", receipt["statement"]["error"]
    fresh = build_release(sequence: 2, version: "2.0.0-alpha.3")
    publish_fixture(fresh)
    assert_equal "STAGED", stage_release(SecureRandom.uuid, fresh)["statement"]["state"]
  end

  test "unqualified UTC and stale cross domain receipts cannot authorize staging" do
    id = SecureRandom.uuid
    assert_equal "trusted_utc_required", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["error"]
    prepare_release(id)
    @release_ticks += 61
    @release_clock.reconcile!(trusted_utc: Time.now.to_f, source: "Synthetic test only")
    assert_equal "time_receipt_stale", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["error"]
    prepare_release(id)
    @release_domain = "different-synthetic-boot"
    assert_equal "clock_anomaly", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["error"]
    assert_empty Dir.children(File.join(@operator_root, "staging"))
  end

  test "expiration persists after forward expiry and backward UTC or host clock" do
    id = SecureRandom.uuid
    prepare_release(id, utc: @release_now.to_i + 3600)
    assert_equal "manifest_expired", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["error"]
    prepare_release(id)
    assert_equal "trusted_utc_rollback", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["error"]
    [ 1, 2, 3, 5 ].each do |step|
      travel_to @release_now - step
      assert_equal "clock_anomaly", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["error"]
    end
    assert_empty Dir.children(File.join(@operator_root, "staging"))
  end

  test "known forward anomaly cannot be bypassed by a valid UTC signature" do
    id = SecureRandom.uuid
    prepare_release(id)
    travel_to @release_now + 3
    assert_equal "clock_anomaly", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["error"]
    assert_empty Dir.children(File.join(@operator_root, "staging"))
  end

  [ -5, -3, -2, -1, 1, 2, 3, 5 ].each do |step|
    test "clock discontinuity #{step} seconds during extraction cannot authorize staged completion" do
      @operator = new_operator(capacity: ->(*) { travel_to(@release_now + step) })
      id = SecureRandom.uuid
      prepare_release(id)
      receipt = @operator.stage(request_id: id, release_id: @release_fixture["release_id"])
      assert_equal "FAILED_STAGED", receipt["statement"]["state"]
      assert_equal "clock_anomaly", receipt["statement"]["error"]
      refute @operator.status["history"].any? { |event| event["state"] == "STAGED" }
      assert_equal false, @operator.status["active_switch_supported"]
    end
  end

  test "publisher revocation observed during extraction prevents staged completion" do
    @operator = new_operator(capacity: lambda do |*|
      @trust["generation"] = 2
      @trust["revoked"] = [ Railpress::Releases.key_id(@release_signer) ]
      write_trust
    end)
    receipt = stage_release
    assert_equal "FAILED_STAGED", receipt["statement"]["state"]
    assert_equal "revoked_publisher", receipt["statement"]["error"]
    refute @operator.status["history"].any? { |event| event["state"] == "STAGED" }
  end

  test "signed progress reports real durable phases and increasing revisions" do
    receipts = []
    @operator = new_operator(progress: ->(receipt) { receipts << receipt })
    result = stage_release
    assert_equal "STAGED", result["statement"]["state"]
    assert_equal %w[PREFLIGHT DOWNLOADING VERIFIED STAGED], receipts.select { |r| r["statement"]["operation"] == "stage" }.map { |r| r["statement"]["state"] }
    assert_equal receipts.map { |r| r["statement"]["revision"] }.sort.uniq, receipts.map { |r| r["statement"]["revision"] }
    receipts.each do |receipt|
      assert_equal Railpress::Releases.key_id(@status_signer), Railpress::Releases.signature!(Railpress::Releases.canonical(receipt["statement"]), receipt["signature"], @keys, purpose: "status")
    end
    assert_equal %w[AVAILABLE PREFLIGHT DOWNLOADING VERIFIED STAGED], result["statement"]["history"].map { |event| event["state"] }
  end

  test "progress delivery failure leaves a durable failed stage and no running release change" do
    id = SecureRandom.uuid
    prepare_release(id)
    @operator = new_operator(progress: ->(*) { raise IOError, "Synthetic bridge outage" })
    assert_raises(Railpress::Releases::Invalid) { @operator.stage(request_id: id, release_id: @release_fixture["release_id"]) }
    status = new_operator.status
    assert_equal "FAILED_STAGED", status["requests"].find { |request| request["id"] == id }["state"]
    assert_equal Railpress::Product::VERSION, status["installed"]["version"]
  end

  test "compatibility rejects runtime schema job theme configuration security and prior release mismatches" do
    mutations = { "ruby" => ">= 9.0", "rails" => "= 8.0.0", "schema_read" => [ 1, 10 ], "schema_write" => [ 1, 10 ],
      "jobs_read" => [ 2, 2 ], "jobs_write" => [ 2, 2 ], "theme_api" => 2, "configuration" => 1, "security_clock" => 1,
      "prior_versions" => [ "0.0.1" ], "themes" => [ { "id" => "dusk", "version" => "9.0.0", "digest" => "a" * 64 } ] }
    mutations.each do |field, value|
      fixture = altered_fixture { |manifest| manifest["compatibility"][field] = value }
      receipt = stage_release(SecureRandom.uuid, fixture)
      assert_equal "FAILED_STAGED", receipt["statement"]["state"], field
      assert receipt["statement"]["error"], field
    end
    assert_empty Dir.children(File.join(@operator_root, "staging"))
  end

  test "capacity failure keeps active identity and supports bounded same request recovery" do
    @operator = new_operator(capacity: ->(*) { raise Railpress::Releases::Invalid, "disk_capacity" })
    id = SecureRandom.uuid
    assert_equal "disk_capacity", stage_release(id)["statement"]["error"]
    assert_equal Railpress::Product::VERSION, @operator.status["installed"]["version"]
    @operator = new_operator
    prepare_release(id)
    assert_equal "STAGED", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["state"]
  end

  test "cancellation retains evidence and prevents staging the cancelled request" do
    id = SecureRandom.uuid
    stage_release(id)
    receipt = @operator.cancel(request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"])
    assert_equal "CANCELLED", receipt["statement"]["state"]
    assert_equal "request_cancelled", @operator.stage(request_id: id, release_id: @release_fixture["release_id"])["statement"]["error"]
    assert_equal 1, Dir.children(File.join(@operator_root, "staging")).length
  end

  test "corrupt missing journal symlink and arbitrary identities fail closed" do
    assert_raises(Railpress::Releases::Invalid) { @operator.inspect(request_id: "../x", release_id: @release_fixture["release_id"]) }
    @operator.status
    File.unlink(File.join(@operator_root, "journal.json"))
    assert_raises(Railpress::Releases::Invalid) { @operator.status }
    File.symlink("/etc/passwd", File.join(@operator_root, "journal.json"))
    assert_raises(Railpress::Releases::Invalid) { @operator.status }
  end

  test "missing native Ruby Rack and Rake entrypoints cannot be staged" do
    %w[.ruby-version config.ru Rakefile bin/rake themes/dusk/templates/page.html.erb themes/dusk/templates/post.html.erb].each do |name|
      fixture = altered_fixture { |manifest| manifest["files"].delete(name) }
      assert_equal "file_inventory", @operator.inspect(request_id: SecureRandom.uuid, release_id: fixture["release_id"])["statement"]["error"]
    end
    assert_empty Dir.children(File.join(@operator_root, "staging"))
  end

  test "untrusted archive paths permissions metadata and resource limits reject before staging" do
    [ "../x", "/tmp/x", "app/../config/x", "app/a\\b", "app/%2e/x", "app/é.rb", "config/master.key", "app/CON.txt", ".git/config" ].each do |path|
      assert_raises(Railpress::Releases::Invalid) { Railpress::Releases.path!(path) }
    end
    assert_raises(Railpress::Releases::Invalid) { Railpress::Releases.parse('{"a":1,"a":2}') }
    mutations = [
      ->(m) { m["files"]["app/BAD.rb"] = m["files"]["config/routes.rb"]; m["files"]["app/bad.rb"] = m["files"]["config/routes.rb"] },
      ->(m) { m["files"]["config/routes.rb"]["mode"] = 0o4755 },
      ->(m) { m["package"]["bytes"] = 33 * 1024 * 1024 },
      ->(m) { m["channel"] = "stable" },
      ->(m) { m["version"] = "01.0.0" },
      ->(m) { m["files"].delete("public/assets/.manifest.json") } ]
    mutations.each do |mutation|
      manifest = Marshal.load(Marshal.dump(@release_fixture["manifest"]))
      mutation.call(manifest)
      assert_raises(Railpress::Releases::Invalid) { Railpress::Releases::Manifest.validate!(manifest) }
    end
  end
end
