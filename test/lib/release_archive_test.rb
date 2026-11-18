require "test_helper"
require_relative "../support/release_test_support"
require "stringio"

class ReleaseArchiveTest < ActiveSupport::TestCase
  include ReleaseTestSupport
  setup { release_setup }
  teardown { release_teardown }

  def archive_fixture(raw)
    buffer = StringIO.new("".b)
    zip = Zlib::GzipWriter.new(buffer)
    zip.mtime = 0
    zip.write(raw)
    zip.close
    fixture = Marshal.load(Marshal.dump(@release_fixture))
    fixture["package"] = buffer.string
    @attack_sequence = (@attack_sequence || 1) + 1
    fixture["manifest"]["sequence"] = @attack_sequence
    fixture["manifest"]["package"] = { "bytes" => buffer.string.bytesize, "sha256" => Digest::SHA256.hexdigest(buffer.string) }
    fixture["release_id"] = Digest::SHA256.hexdigest(Railpress::Releases.canonical(fixture["manifest"]))
    fixture["signature"] = signed(fixture["manifest"], @release_signer)
    publish_fixture(fixture)
    fixture
  end
  def raw_archive
    Zlib::GzipReader.wrap(StringIO.new(@release_fixture["package"])) { |gzip| gzip.read }
  end
  def rewrite_header(raw, offset: 0, **attributes)
    header = Gem::Package::TarHeader.from(StringIO.new(raw[offset, 512]))
    values = %i[name prefix mode size mtime uid gid typeflag linkname uname gname devmajor devminor].to_h { |key| [ key, header.public_send(key) ] }
    raw[offset, 512] = Gem::Package::TarHeader.new(**values.merge(attributes)).to_s
    raw
  end
  def assert_rejected(fixture)
    receipt = stage_release(SecureRandom.uuid, fixture)
    assert_equal "FAILED_STAGED", receipt["statement"]["state"]
    assert receipt["statement"]["error"]
    refute_equal "manifest_replay", receipt["statement"]["error"]
    assert_equal Railpress::Product::VERSION, @operator.status["installed"]["version"]
  end

  test "signed malicious tar traversal absolute symlinks hardlinks and unsafe modes reject" do
    [
      { name: "../escape", prefix: "" }, { name: "/tmp/escape", prefix: "" },
      { name: "alias", typeflag: "2", linkname: "/etc/passwd" },
      { name: "alias", typeflag: "1", linkname: "Gemfile" },
      { typeflag: "x" }, { mode: 0o777 }, { uid: 1 }
    ].each do |attributes|
      assert_rejected archive_fixture(rewrite_header(raw_archive.dup, **attributes))
    end
    assert_empty Dir.children(File.join(@operator_root, "staging")).reject { |name| name.start_with?("extract-") }
    refute File.exist?(File.join(@operator_root, "escape"))
  end

  test "duplicate tar paths checksum errors truncation and trailing bytes reject" do
    raw = raw_archive
    header = Gem::Package::TarHeader.from(StringIO.new(raw[0, 512]))
    entry_length = 512 + header.size + (512 - header.size % 512) % 512
    duplicate = raw[0, entry_length] + raw
    assert_rejected archive_fixture(duplicate)
    broken = raw.dup
    broken.setbyte(1, (broken.getbyte(1) + 1) % 128)
    assert_rejected archive_fixture(broken)
    assert_rejected archive_fixture(raw[0...-1024])
    assert_rejected archive_fixture(raw + "unexpected")
  end

  test "missing inventory entries and content hashes reject even when package signature is valid" do
    raw = raw_archive
    header = Gem::Package::TarHeader.from(StringIO.new(raw[0, 512]))
    entry_length = 512 + header.size + (512 - header.size % 512) % 512
    assert_rejected archive_fixture(raw[entry_length..])
    broken = raw.dup
    broken.setbyte(512, broken.getbyte(512) ^ 1)
    assert_rejected archive_fixture(broken)
  end

  test "gzip corruption and excessive expansion are bounded" do
    fixture = Marshal.load(Marshal.dump(@release_fixture))
    fixture["package"] = @release_fixture["package"][0...-8]
    fixture["manifest"]["package"] = { "bytes" => fixture["package"].bytesize, "sha256" => Digest::SHA256.hexdigest(fixture["package"]) }
    fixture["release_id"] = Digest::SHA256.hexdigest(Railpress::Releases.canonical(fixture["manifest"]))
    fixture["signature"] = signed(fixture["manifest"], @release_signer)
    publish_fixture(fixture)
    assert_rejected fixture
    # Actual streaming cap exercised with a small temporary constant, not an increased budget.
    original = Railpress::Releases::Manifest::MAX_EXPANDED
    Railpress::Releases::Manifest.send(:remove_const, :MAX_EXPANDED)
    Railpress::Releases::Manifest.const_set(:MAX_EXPANDED, @release_fixture["manifest"]["files"].values.sum { |row| row["bytes"] } + 1)
    excessive = archive_fixture("x" * (Railpress::Releases::Manifest::MAX_EXPANDED + 4096 * 1536 + 1))
    assert_equal "archive_resource_limit", stage_release(SecureRandom.uuid, excessive)["statement"]["error"]
  ensure
    if original
      Railpress::Releases::Manifest.send(:remove_const, :MAX_EXPANDED)
      Railpress::Releases::Manifest.const_set(:MAX_EXPANDED, original)
    end
  end

  test "tampered staged bytes and symlink destinations are refused on idempotent retry" do
    id = SecureRandom.uuid
    stage_release(id)
    path = File.join(@operator_root, "staging", @release_fixture["release_id"], "Gemfile")
    File.chmod(0o644, path)
    File.write(path, "changed")
    receipt = new_operator.stage(request_id: id, release_id: @release_fixture["release_id"])
    assert_equal "staged_digest", receipt["statement"]["error"]
    assert_equal "FAILED_STAGED", receipt["statement"]["state"]
    assert_equal false, receipt["statement"]["activation_supported"]
  end

  test "real process concurrency serializes one staging transaction and restart reads durable result" do
    id = SecureRandom.uuid
    prepare_release(id)
    readers = []
    children = 2.times.map do
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        result = new_operator.stage(request_id: id, release_id: @release_fixture["release_id"])
        writer.write(JSON.generate(result["statement"]))
        writer.close
        exit! 0
      end
      writer.close
      readers << reader
      pid
    end
    results = readers.map { |io| JSON.parse(io.read.tap { io.close }) }
    children.each { |pid| Process.wait(pid); assert_predicate $?, :success? }
    assert_equal [ "STAGED", "STAGED" ], results.map { |row| row["state"] }
    assert_equal 1, new_operator.status["history"].count { |row| row["state"] == "STAGED" }
    assert_equal 1, Dir.children(File.join(@operator_root, "staging")).length
  end

  test "interrupted native extraction remains isolated and same request resumes after restart" do
    id = SecureRandom.uuid
    prepare_release(id)
    # Persist a real intermediate journal phase; no active path exists or is switched.
    @operator.journal.transaction do |state|
      request = state["requests"].fetch(id)
      @operator.journal.transition!(state, request, "PREFLIGHT")
      @operator.journal.transition!(state, request, "DOWNLOADING")
    end
    @operator = new_operator
    receipt = @operator.stage(request_id: id, release_id: @release_fixture["release_id"])
    assert_equal "STAGED", receipt["statement"]["state"]
    assert @operator.status["history"].any? { |row| row["detail"] == "interrupted_before_promotion" }
    @operator.journal.transaction do |state|
      assert_raises(Railpress::Releases::Invalid) { @operator.journal.transition!(state, state["requests"].fetch(id), "SCHEMA_EXPANDED") }
    end
  end

  test "cancellation remains safe after publisher revocation and lost package metadata" do
    id = SecureRandom.uuid
    stage_release(id)
    @trust["generation"] = 2
    @trust["revoked"] = [ Railpress::Releases.key_id(@release_signer) ]
    write_trust
    File.unlink(File.join(@operator_root, "inbox", @release_fixture["release_id"], "manifest.json"))
    receipt = new_operator.cancel(request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"])
    assert_equal "CANCELLED", receipt["statement"]["state"]
    assert_nil receipt["statement"]["error"]
    assert_equal "CANCELLED", new_operator.status["requests"].find { |row| row["id"] == id }["state"]
    assert_equal 1, Dir.children(File.join(@operator_root, "staging")).length
  end

  test "actual native kill after extracted bytes recovers without promotion" do
    id = SecureRandom.uuid
    prepare_release(id)
    pid = fork do
      original = Railpress::Releases::Bundle.method(:verify_tree!)
      Railpress::Releases::Bundle.define_singleton_method(:verify_tree!) do |*args|
        original.call(*args)
        Process.kill("KILL", Process.pid)
      end
      new_operator.stage(request_id: id, release_id: @release_fixture["release_id"])
      exit! 1
    end
    Process.wait(pid)
    assert_predicate $?, :signaled?
    assert_equal Signal.list.fetch("KILL"), $?.termsig
    assert_equal "VERIFIED", new_operator.status["requests"].find { |row| row["id"] == id }["state"]
    assert_equal Railpress::Product::VERSION, new_operator.status["installed"]["version"]
    assert Dir.children(File.join(@operator_root, "staging")).any? { |name| name.start_with?("extract-") }
    receipt = new_operator.stage(request_id: id, release_id: @release_fixture["release_id"])
    assert_equal "STAGED", receipt["statement"]["state"]
    assert_nil receipt["statement"]["error"]
  end

  test "invalid known key signatures and wrong key purposes fail before extraction" do
    path = publish_fixture(@release_fixture)
    signature = @release_fixture["signature"].merge("signature" => Base64.strict_encode64("x" * 64))
    File.write(File.join(path, "signature.json"), JSON.generate(signature))
    assert_equal "invalid_signature", @operator.inspect(request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"])["statement"]["error"]
    File.write(File.join(path, "signature.json"), JSON.generate(signed(@release_fixture["manifest"], @time_signer)))
    assert_equal "key_purpose", @operator.inspect(request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"])["statement"]["error"]
    assert_empty Dir.children(File.join(@operator_root, "staging"))
  end
end
