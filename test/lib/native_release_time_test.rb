require "test_helper"
require Rails.root.join("lib/railpress/native_host")

class NativeReleaseTimeTest < ActiveSupport::TestCase
  class Clock
    attr_accessor :ticks, :anomaly, :domain, :epoch
    def initialize
      @ticks, @domain, @epoch = 1000.0, "controlled-native-time", "e" * 64
    end
    def sample = { "elapsed" => ticks, "domain" => domain, "epoch" => epoch, "anomaly" => anomaly }
  end
  setup do
    @clock = Clock.new
    @signer = OpenSSL::PKey.generate_key("ED25519")
    @authority = Railpress::Releases::Authority.new({ "format" => "railpress.trust.v1", "generation" => 1,
      "keys" => { Railpress::Releases.key_id(@signer) => { "purpose" => "time", "public_key" => @signer.public_to_pem } }, "revoked" => [] })
    @state = { "utc_max" => 0, "revoked" => [] }
    @time = Railpress::Releases::ReleaseTime.new(@clock)
  end
  def verify(challenge, utc_ns)
    row = { "format" => "railpress.utc.v2", **challenge, "utc_ns" => utc_ns.to_s }
    @time.verify!(challenge, Railpress::NativeHost.sign(row, @signer), @authority, @state)
  end
  test "precise successive anchors avoid false rollback while retaining the high water mark" do
    first = @time.challenge
    @clock.ticks = 1000.8
    assert_equal Rational(18_000_000_008, 10), verify(first, 1_800_000_000_000_000_000)
    @clock.ticks = 1000.9
    second = @time.challenge
    @clock.ticks = 1001.0
    assert_equal 1_800_000_001, verify(second, 1_800_000_000_900_000_000)
    assert_equal "1800000001000000000", @state["utc_max_ns"]
    error = assert_raises(Railpress::Releases::Invalid) { verify(second, 1_800_000_000_899_999_999) }
    assert_equal "trusted_utc_rollback", error.message
  end
  test "precision cannot bypass stale domain epoch anomaly signature or bounded fields" do
    challenge = @time.challenge
    @clock.ticks += 61
    assert_equal "time_receipt_stale", assert_raises(Railpress::Releases::Invalid) { verify(challenge, 1_800_000_000_000_000_000) }.message
    @clock.ticks = 1000
    @clock.domain = "other-domain"
    assert_equal "time_receipt_stale", assert_raises(Railpress::Releases::Invalid) { verify(challenge, 1_800_000_000_000_000_000) }.message
    @clock.domain = challenge["domain"]
    @clock.anomaly = { "code" => "injected" }
    assert_equal "clock_anomaly", assert_raises(Railpress::Releases::Invalid) { verify(challenge, 1_800_000_000_000_000_000) }.message
    @clock.anomaly = nil
    [ 0, -1, "1e99", "9" * 25 ].each { |value| assert_raises(Railpress::Releases::Invalid) { verify(challenge, value) } }
    row = { "format" => "railpress.utc.v2", **challenge, "utc_ns" => "1800000000000000000" }
    receipt = Railpress::NativeHost.sign(row, @signer)
    receipt["statement"]["utc_ns"] = "1800000001000000000"
    assert_equal "invalid_signature", assert_raises(Railpress::Releases::Invalid) { @time.verify!(challenge, receipt, @authority, @state) }.message
  end
  test "legacy integer receipts retain their conservative fail closed behavior" do
    challenge = @time.challenge
    @clock.ticks = 1000.8
    row = { "format" => "railpress.utc.v1", **challenge, "utc" => 1_800_000_000 }
    @time.verify!(challenge, Railpress::NativeHost.sign(row, @signer), @authority, @state)
    @clock.ticks = 1000.9
    challenge = @time.challenge
    @clock.ticks = 1001.0
    row = { "format" => "railpress.utc.v1", **challenge, "utc" => 1_800_000_000 }
    assert_equal "trusted_utc_rollback", assert_raises(Railpress::Releases::Invalid) { @time.verify!(challenge, Railpress::NativeHost.sign(row, @signer), @authority, @state) }.message
  end
  test "shared anti rollback evidence unions expiry revocation precise UTC and reservations" do
    target = { "trust_generation" => 0, "utc_max" => 0, "revoked" => [], "expired" => [], "sequence" => {} }
    source = { "trust_generation" => 1, "trust_digest" => "d" * 64, "accepted_roots" => {}, "utc_max" => 1_800_000_000.5,
      "utc_max_ns" => "1800000000500000000", "revoked" => [ "a" * 64 ], "expired" => [ "b" * 64 ],
      "sequence" => { "development" => { "sequence" => 2, "release_id" => "c" * 64, "request_id" => SecureRandom.uuid } } }
    Railpress::Releases::ReplayState.merge!(target, source)
    assert_equal source, target
    old = source.deep_dup.merge("utc_max" => 0, "utc_max_ns" => "1700000000000000000", "revoked" => [], "expired" => [])
    Railpress::Releases::ReplayState.merge!(target, old)
    assert_equal source, target
    conflict = source.deep_dup
    conflict["sequence"]["development"]["request_id"] = SecureRandom.uuid
    assert_equal "replay_sequence_conflict", assert_raises(Railpress::Releases::Invalid) { Railpress::Releases::ReplayState.merge!(target, conflict) }.message
  end
end
