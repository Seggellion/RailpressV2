# frozen_string_literal: true

require "test_helper"
require "railpress/recovery"

class CandidateWithdrawalReplayTest < ActiveSupport::TestCase
  Recovery = Railpress::Recovery
  Releases = Railpress::Releases
  Ledger = Recovery::Revocations
  Withdrawals = Railpress::Extensions::CandidateWithdrawals
  MODULE_ID = "railpress-recruitment"

  setup do
    @signer = OpenSSL::PKey.generate_key("ED25519")
    @site, @snapshot, @subject = Array.new(3) { SecureRandom.uuid }
    @coverage = { key: @signer, site: @site, checkpoint: 7, observed_head: 9, now: 1_800_000_000,
      snapshot: @snapshot, packages: "b" * 64, package_ids: [ MODULE_ID, "neutral-probe" ], candidate_modules: [ MODULE_ID ] }
    @statement = { "format" => Ledger::CANDIDATE_FORMAT, "site" => @site, "snapshot" => @snapshot, "packages" => "b" * 64,
      "from" => 7, "through" => 9, "issued_at" => @coverage[:now] - 10, "expires_at" => @coverage[:now] + 120,
      "events" => [
        { "sequence" => 8, "kind" => "candidate_withdrawn", "module_id" => MODULE_ID, "subject_id" => @subject },
        { "sequence" => 9, "kind" => "module_withdrawn", "module_id" => "neutral-probe" }
      ] }
  end

  test "typed coverage produces separate candidate and module instructions" do
    verified = Ledger.verify_restore!(signed(@statement), **@coverage)
    assert_equal [ [ MODULE_ID, @subject ] ], verified.candidates
    assert_equal [ "neutral-probe" ], verified.modules
    duplicate = @statement.merge("events" => [ @statement["events"].first, @statement["events"].first.merge("sequence" => 9) ])
    assert_equal verified.candidates, Ledger.verify_restore!(signed(duplicate), **@coverage).candidates
    empty = @statement.merge("events" => [], "through" => 7)
    assert_empty Ledger.verify_restore!(signed(empty), **@coverage.merge(observed_head: 7)).candidates
  end

  test "untrusted altered mismatched or stale coverage is refused" do
    assert_raises(Recovery::Error) { Ledger.verify_restore!(signed(@statement.merge("from" => 7.0)), **@coverage) }
    [
      { key: OpenSSL::PKey.generate_key("ED25519") }, { site: SecureRandom.uuid }, { snapshot: SecureRandom.uuid },
      { packages: "c" * 64 }, { checkpoint: 6 }, { observed_head: 10 }, { now: @coverage[:now] + 300 },
      { now: @coverage[:now] - 11 }, { candidate_modules: [] }, { package_ids: [ MODULE_ID ] }
    ].each do |override|
      assert_raises(Recovery::Error) { Ledger.verify_restore!(signed(@statement), **@coverage.merge(override)) }
    end
    altered = Releases.parse(signed(@statement))
    altered["statement"]["events"].first["subject_id"] = SecureRandom.uuid
    assert_raises(Recovery::Error) { Ledger.verify_restore!(Releases.canonical(altered), **@coverage) }
  end

  test "typed coverage rejects unknown malformed and out of order events" do
    event, second = @statement["events"]
    [
      [ event ], [ second, event ], [ event.merge("sequence" => 8.0), second ], [ event.merge("kind" => "candidate_restored"), second ],
      [ event.merge("subject_id" => "candidate@example.invalid"), second ],
      [ event.merge("extra" => "profile"), second ], [ event.merge("module_id" => "neutral-probe"), second ]
    ].each do |events|
      assert_raises(Recovery::Error) { Ledger.verify_restore!(signed(@statement.merge("events" => events)), **@coverage) }
    end
  end

  test "legacy module-only ledgers stay valid for legacy package sets" do
    legacy = @statement.except("snapshot", "packages").merge("format" => Ledger::FORMAT, "from" => 8,
      "events" => [ @statement["events"].last ])
    assert_raises(Recovery::Error) { Ledger.verify_restore!(signed(legacy), **@coverage.merge(checkpoint: 8)) }
    result = Ledger.verify_restore!(signed(legacy), **@coverage.merge(checkpoint: 8, candidate_modules: []))
    assert_equal [ "neutral-probe" ], result.modules
    assert_empty result.candidates
  end

  test "withdrawal lookup is scoped to a site and module" do
    PlatformState.create!(scope_name: Withdrawals.scope(@site, MODULE_ID), key_name: @subject, payload: {})
    assert Withdrawals.withdrawn?(@site, MODULE_ID, @subject)
    assert_not Withdrawals.withdrawn?(@site, MODULE_ID, SecureRandom.uuid)
    assert_not Withdrawals.withdrawn?(SecureRandom.uuid, MODULE_ID, @subject)
    assert_not Withdrawals.withdrawn?(@site, "neutral-probe", @subject)
  end

  private

  def signed(statement)
    Releases.canonical(Railpress::NativeHost.sign(statement, @signer))
  end
end
