require "test_helper"
require_relative "../support/editorial_test_support"
require_relative "../support/security_clock_test_support"

class ClockSecurityTest < ActionDispatch::IntegrationTest
  include EditorialTestSupport
  include SecurityClockTestSupport

  test "sessions and private previews never revive across observed expiry and rollback" do
    matrix = []
    [ 1, 2, 3, 5 ].each do |seconds|
      base = Time.current
      token = UserSession.issue!(@owner)
      deadline = UserSession.find_by!(token_digest: Digest::SHA256.hexdigest(token)).expires_at
      travel_to(deadline + 0.25, with_usec: true) { assert_nil UserSession.resolve(token) }
      travel_to(deadline + 0.25 - seconds, with_usec: true) { assert_nil UserSession.resolve(token) }
      preview, secret = Editorial::Previews.issue!(actor: @owner, content: draft(slug: "private-#{seconds}"))
      travel_to(preview.expires_at + 0.25, with_usec: true) do
        assert_raises(ActiveRecord::RecordNotFound) { Editorial::Previews.resolve!(actor: @owner, id: preview.id, token: secret) }
      end
      travel_to(preview.expires_at + 0.25 - seconds, with_usec: true) do
        assert_raises(ActiveRecord::RecordNotFound) { Editorial::Previews.resolve!(actor: @owner, id: preview.id, token: secret) }
        get "/blog/private-#{seconds}"; assert_response :not_found
      end
      matrix << { backward_seconds: seconds, session_revived: false, preview_revived: false, private_public_status: response.status }
      travel_to(base)
    end
    clock_evidence("security-expiry-matrix", { matrix: matrix, host_clock_changed: false })
  end

  test "elapsed cap expires sessions and resets even if wall time remains behind" do
    with_controlled_security_clock do |_clock, ticks|
      token = UserSession.issue!(@owner)
      reset = create_recovery_token
      assert UserSession.resolve(token)
      ticks[:value] += PasswordReset::LIFETIME + 1
      travel(-1.hour) do
        assert_raises(Identity::PasswordRecovery::InvalidToken) { Identity::PasswordRecovery.complete!(token: reset, password: PASSWORD, confirmation: PASSWORD) }
      end
      ticks[:value] += UserSession::LIFETIME
      travel(-1.hour) { assert_nil UserSession.resolve(token) }
    end
  end

  test "expiry observation survives a surrounding SQL rollback and another request" do
    token = UserSession.issue!(@owner)
    row = UserSession.find_by!(token_digest: Digest::SHA256.hexdigest(token))
    travel_to(row.expires_at + 1) do
      UserSession.transaction do
        assert_nil UserSession.resolve(token)
        raise ActiveRecord::Rollback
      end
    end
    assert_nil row.reload.deadline_expired_at, "Control: SQL expiration audit was rolled back"
    assert_nil UserSession.resolve(token), "Private observed-wall journal must retain the expiration decision"
  end

  test "same boot replacement retains valid deadlines but changed domain and lost epoch fail closed" do
    with_controlled_security_clock do |clock, ticks|
      token = UserSession.issue!(@owner)
      replacement = Railpress::SecurityClock.new(@private_root, elapsed: -> { ticks[:value] }, domain: -> { ticks[:domain] })
      replacing_method(Railpress::SecurityClock, :for_application, -> { replacement }) { assert UserSession.resolve(token) }
      ticks[:domain] = "another-supported-boot-domain"
      assert_nil UserSession.resolve(token)
      refute clock.scheduling_allowed?, "Changed boot domain must hold new scheduled transitions"
      ticks[:domain] = "synthetic-supported-boot-domain"
      assert_nil UserSession.resolve(token)
      new_token = UserSession.issue!(@owner)
      assert UserSession.resolve(new_token)
      File.unlink(File.join(@private_root, "security-clock.json"))
      assert_nil UserSession.resolve(new_token)
      refute clock.scheduling_allowed?, "Lost installed clock authority must hold scheduling"
      assert clock.sample
    end
  end

  test "legacy bindings malformed clock and exhausted observation history deny without renewing" do
    token = UserSession.issue!(@owner)
    row = UserSession.find_by!(token_digest: Digest::SHA256.hexdigest(token))
    original_expiry = row.expires_at
    row.update_columns(deadline_binding: nil)
    assert_nil UserSession.resolve(token)
    assert_equal original_expiry, row.reload.expires_at
    fresh = UserSession.issue!(@owner)
    File.write(File.join(@private_root, "security-clock.json"), "[]", perm: 0o600)
    assert_nil UserSession.resolve(fresh)
    assert_raises(Railpress::SecurityClock::Unavailable) { UserSession.issue!(@owner) }
  end

  test "bounded history cannot reactivate old credentials when earlier excursions are discarded" do
    with_controlled_security_clock do |_clock, ticks|
      token = UserSession.issue!(@owner)
      base = Time.current
      (Railpress::SecurityClock::HISTORY + 1).times do |index|
        ticks[:value] += 0.1
        travel_to(base - index - 1) { Railpress::SecurityClock.for_application.sample }
      end
      assert_nil UserSession.resolve(token)
    end
  end

  test "reset expiry replay and explicit consumption remain irreversible under races" do
    token = create_recovery_token
    row = PasswordReset.find_by!(token_digest: Digest::SHA256.hexdigest(token))
    travel_to(row.expires_at + 1) do
      assert_raises(Identity::PasswordRecovery::InvalidToken) { Identity::PasswordRecovery.complete!(token: token, password: PASSWORD, confirmation: PASSWORD) }
    end
    assert_raises(Identity::PasswordRecovery::InvalidToken) { Identity::PasswordRecovery.complete!(token: token, password: PASSWORD, confirmation: PASSWORD) }
    fresh = create_recovery_token
    results = parallel_results(2) do
      Identity::PasswordRecovery.complete!(token: fresh, password: PASSWORD, confirmation: PASSWORD)
      :consumed
    rescue Identity::PasswordRecovery::InvalidToken
      :denied
    end
    assert_equal [ :consumed, :denied ], results.sort
    travel(-5.seconds) do
      assert_raises(Identity::PasswordRecovery::InvalidToken) { Identity::PasswordRecovery.complete!(token: fresh, password: PASSWORD, confirmation: PASSWORD) }
    end
  end

  test "resolve and explicit session revocation have a serializable final denial" do
    token = UserSession.issue!(@owner)
    digest = Digest::SHA256.hexdigest(token)
    results = parallel_results(2) do |index|
      if index.zero?
        UserSession.resolve(token) ? :resolved : :denied
      else
        UserSession.where(token_digest: digest).delete_all
        :revoked
      end
    end
    assert_includes results, :revoked
    travel(-5.seconds) { assert_nil UserSession.resolve(token) }
    assert_equal 0, UserSession.where(token_digest: digest).count
  end

  test "a separate native process resolves the same boot credential and committed publication" do
    item = nil
    travel(1.hour) { item = change(draft(slug: "restart-public"), "publish") }
    assert_operator item.published_at, :>, Time.current
    token = UserSession.issue!(@owner)
    log = Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-credential-process.log")
    code = 'raise "session denied" unless UserSession.resolve(ENV.fetch("SYNTHETIC_CLOCK_TOKEN")); raise "publication missing" unless Post.publicly_visible.exists?(slug: "restart-public"); puts "SAME_BOOT_PROCESS_SESSION_AND_PUBLICATION_PASS"'
    pid = Process.spawn({ "SYNTHETIC_CLOCK_TOKEN" => token }, RbConfig.ruby, Rails.root.join("bin/rails").to_s, "runner", code, out: log.to_s, err: [ :child, :out ])
    _, status = Process.wait2(pid)
    assert status.success?, File.read(log)
    assert_equal "published", item.reload.status
    assert UserSession.resolve(token)
  end

  test "scheduling holds detected forward and backward anomalies while published state survives" do
    with_controlled_security_clock do |clock, ticks|
      base = Time.current
      committed = change(draft(slug: "committed"), "publish")
      scheduled = draft(slug: "held-schedule")
      change(scheduled, "schedule", attributes: { schedule_local: 2.hours.from_now.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M") })
      version = scheduled.lock_version
      travel_to(base + 3.hours) do
        refute PublishContentJob.perform_now(scheduled.id, version)
        assert_equal "scheduled", scheduled.reload.status
        get "/blog/held-schedule"; assert_response :not_found
        assert_equal "DEGRADED", Readiness::Probes.security_time["state"]
        assert committed.reload.publicly_visible?
      end
      ticks[:value] += 1
      assert clock.sample["anomaly"], "Detected anomaly is durable across time recovery"
      refute PublishContentJob.perform_now(scheduled.id, version)
      travel_to(base + 3.hours) do
        assert clock.reconcile!(trusted_utc: Time.now.to_f, source: "Controlled test UTC authority")
        assert PublishContentJob.perform_now(scheduled.id, version)
        refute PublishContentJob.perform_now(scheduled.id, version)
      end
      travel_to(base - 5.seconds) do
        get "/blog/held-schedule"; assert_response :ok
        assert committed.reload.publicly_visible?
      end
      assert_equal 1, scheduled.content_revisions.where(event: "scheduled_publish").count
    end
  end
  test "unavailable security time denies sign in predictably while committed public rendering works" do
    change(draft(slug: "clock-unavailable-public"), "publish")
    replacing_method(Railpress::SecurityClock, :elapsed, -> { raise Railpress::SecurityClock::Unavailable }) do
      get "/blog/clock-unavailable-public"; assert_response :ok
      get "/sitemap.xml"; assert_response :ok
      sign_in
      assert_response :service_unavailable
      assert_includes response.body, "Security time could not be verified"
      refute_includes response.body, PASSWORD
      assert_equal 0, UserSession.count
    end
    sign_in
    assert_response :see_other
    get "/admin"; assert_response :ok
  end
end
