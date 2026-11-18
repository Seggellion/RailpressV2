require "test_helper"
require_relative "../support/editorial_test_support"
require_relative "../support/security_clock_test_support"
class SchedulingFixtureClockTest < ActiveSupport::TestCase
  include EditorialTestSupport
  include SecurityClockTestSupport
  test "a frozen wall with advancing elapsed reproduces the intended scheduling hold" do
    with_controlled_security_clock do |clock, ticks|
      item = draft
      due = 2.hours.from_now.change(sec: 0)
      change(item, "schedule", attributes: { schedule_local: due.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M") })
      version = item.lock_version
      Identity::ManageUsers.change_role!(actor: @owner, user: @editor, role: "author")
      with_qualified_utc(due + 1.second) do
        before = clock.sample.slice("wall", "elapsed", "anomaly")
        assert_nil before["anomaly"]
        ticks[:value] += 0.6
        refute PublishContentJob.new.perform(item.id, version)
        after = clock.sample.slice("wall", "elapsed", "anomaly")
        assert_equal "scheduled", item.reload.status
        assert_nil item.published_snapshot
        assert_in_delta(-0.6, after.fetch("anomaly").fetch("delta"), 0.0001)
        clock_evidence("frozen-wall-scheduling-hold", { before: before, after: after, scheduled_status: item.status, actual_host_clock_changed: false, production_controls_changed: false })
      end
    end
  end
end
