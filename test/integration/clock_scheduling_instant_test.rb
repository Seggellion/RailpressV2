require "test_helper"
require_relative "../support/editorial_test_support"
require_relative "../support/security_clock_test_support"

class ClockSchedulingInstantTest < ActiveSupport::TestCase
  include EditorialTestSupport
  include ActiveJob::TestHelper
  include SecurityClockTestSupport

  test "due eligibility uses the guard's captured instant rather than another unsampled wall read" do
    base = Time.current
    item = draft(slug: "captured-clock-schedule")
    change(item, "schedule", attributes: { schedule_local: 2.hours.from_now.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M") })
    clock = Object.new
    clock.define_singleton_method(:scheduling_allowed?) { true }
    clock.define_singleton_method(:scheduling_instant) { base }
    result = nil
    replacing_method(Railpress::SecurityClock, :for_application, -> { clock }) do
      travel(3.hours) { result = PublishContentJob.perform_now(item.id, item.lock_version) }
    end
    clock_evidence("captured-scheduling-instant", { guard_qualified_utc: base.iso8601(6), unrelated_wall_advanced_hours: 3,
      scheduled_transition_committed: !!result, content_state: item.reload.status, host_clock_changed: false })
    refute result, "An unsampled forward wall read must not override a not-yet-due qualified instant"
    assert_equal "scheduled", item.reload.status
  end
  test "locked due eligibility rechecks the approved instant after waiting for content locks" do
    base = Time.current
    item = draft(slug: "locked-clock-schedule")
    change(item, "schedule", attributes: { schedule_local: 2.hours.from_now.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M") })
    instants = [ item.scheduled_at + 1, base ]
    clock = Object.new
    clock.define_singleton_method(:scheduling_instant) { instants.shift }
    replacing_method(Railpress::SecurityClock, :for_application, -> { clock }) do
      travel(3.hours) { refute PublishContentJob.perform_now(item.id, item.lock_version) }
    end
    assert_equal "scheduled", item.reload.status
  end

  test "due sweep does not enqueue work using an unsampled forward wall read" do
    base = Time.current
    item = draft(slug: "sweep-clock-schedule")
    change(item, "schedule", attributes: { schedule_local: 2.hours.from_now.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M") })
    clock = Object.new
    clock.define_singleton_method(:scheduling_instant) { base }
    replacing_method(Railpress::SecurityClock, :for_application, -> { clock }) do
      travel(3.hours) { assert_no_enqueued_jobs { PublishDueContentJob.perform_now } }
    end
    assert_equal "scheduled", item.reload.status
  end
end
