require "test_helper"

class BootstrapStateTest < ActiveSupport::TestCase
  include IdentityTestSupport

  test "operator secrets and claims are hashed, private, expiring and consumed" do
    secret = @state.issue!
    assert_match(/\A[0-9a-f]{64}\z/, secret)
    file = File.join(@private_root, "setup.json")
    refute_includes File.read(file), secret
    assert_equal 0o600, File.stat(file).mode & 0o777
    assert_equal 0o700, File.stat(@private_root).mode & 0o777
    claim = @state.claim!(secret)
    assert @state.claimed?(claim)
    refute_includes File.read(file), claim
    assert_raises(Railpress::BootstrapState::InvalidClaim) { @state.claim!(secret) }
    travel 11.minutes do
      refute @state.claimed?(claim)
      assert_raises(Railpress::BootstrapState::InvalidClaim) { @state.complete!(claim) { SecureRandom.uuid } }
    end
  end

  test "expired secret and bounded invalid attempts cannot claim" do
    secret = @state.issue!
    travel 31.minutes do
      assert_raises(Railpress::BootstrapState::InvalidClaim) { @state.claim!(secret) }
    end
    secret = @state.issue!
    8.times { assert_raises(Railpress::BootstrapState::InvalidClaim) { @state.claim!("0" * 64) } }
    assert_raises(Railpress::BootstrapState::InvalidClaim) { @state.claim!(secret) }
    replacement = @state.issue!
    assert @state.claimed?(@state.claim!(replacement))
  end

  test "concurrent secret claims yield exactly one claim" do
    secret = @state.issue!
    results = parallel_results(2) do
      @state.claim!(secret)
    rescue Railpress::BootstrapState::InvalidClaim
      :refused
    end
    assert_equal 1, results.count(:refused)
    assert @state.claimed?((results - [ :refused ]).first)
  end

  test "installed state contains no setup digest and refuses new secrets" do
    secret = @state.issue!
    claim = @state.claim!(secret)
    id = SecureRandom.uuid
    @state.complete!(claim) { id }
    assert @state.installed?
    assert_equal id, @state.install_id
    document = JSON.parse(File.read(File.join(@private_root, "setup.json")))
    assert_equal %w[install_id status version], document.keys.sort
    assert_raises(Railpress::BootstrapState::Closed) { @state.issue! }
    assert_raises(Railpress::BootstrapState::Closed) { @state.complete!(claim) { flunk } }
  end

  test "corrupt, public or symlinked state fails closed" do
    file = File.join(@private_root, "setup.json")
    File.write(file, "{", mode: "w", perm: 0o600)
    assert_raises(Railpress::BootstrapState::Corrupt) { @state.installed? }
    File.unlink(file)
    @state.issue!
    File.chmod(0o644, file)
    assert_raises(Railpress::BootstrapState::Corrupt) { @state.installed? }
    File.unlink(file)
    File.symlink(File.join(@private_root, "missing"), file)
    assert_raises(Railpress::BootstrapState::Corrupt) { @state.installed? }
  end

  test "operator status is read-only and never emits bootstrap digests" do
    require "open3"
    secret = @state.issue!
    output, result = Open3.capture2e(RbConfig.ruby, "bin/railpress", "status")
    assert result.success?
    assert_equal({ "installed" => false, "install_id" => nil }, JSON.parse(output))
    refute_includes output, secret
    refute_includes output, Digest::SHA256.hexdigest(secret)
  end

  test "noninteractive operator tool refuses without emitting or creating a secret" do
    require "open3"
    output, status = Open3.capture2e(RbConfig.ruby, "bin/railpress", "setup-token")
    refute status.success?
    assert_includes output, "Interactive terminal required"
    refute File.exist?(File.join(@private_root, "setup.json"))
  end
end
