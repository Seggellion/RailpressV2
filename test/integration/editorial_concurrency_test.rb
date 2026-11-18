require "test_helper"
require_relative "../support/security_clock_test_support"
require "active_job/test_helper"
require_relative "../support/editorial_test_support"

class EditorialConcurrencyTest < ActiveSupport::TestCase
  include SecurityClockTestSupport
  include EditorialTestSupport
  include ActiveJob::TestHelper
  test "two concurrent editors produce one save and an observable conflict" do
    item = draft
    version = item.lock_version
    outcomes = parallel_results(2) do |index|
      change(Content.find(item.id), actor: User.find(@editor.id), version: version, attributes: { title: "Winner #{index}" })
      :saved
    rescue Editorial::Workflow::Conflict
      :conflict
    end
    assert_equal [ :conflict, :saved ], outcomes.sort
    assert_equal 2, item.content_revisions.count
    assert_equal 1, item.reload.lock_version
    assert_match(/Winner/, item.title)
  end
  test "two native slug creations yield exactly one aggregate and revision" do
    outcomes = parallel_results(2) do |index|
      draft("Page", actor: User.find(@editor.id), slug: index.zero? ? "Café" : "CAFE")
      :created
    rescue ActiveRecord::RecordNotUnique
      :collision
    end
    assert_equal [ :collision, :created ], outcomes.sort
    assert_equal 1, Content.count
    assert_equal 1, ContentRevision.count
  end
  test "duplicate due jobs publish once and stale delivery cannot publish later edits" do
    item = draft
    due = 2.hours.from_now.change(sec: 0)
    local = due.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M")
    change(item, "schedule", attributes: { schedule_local: local })
    version = item.lock_version
    refute PublishContentJob.new.perform(item.id, version)
    with_controlled_security_clock do
    with_qualified_utc(due + 1.second) do
      outcomes = parallel_results(2) { PublishContentJob.new.perform(item.id, version) }
      assert_equal 1, outcomes.count(true)
      assert_equal 1, outcomes.count(false)
      assert_equal "published", item.reload.status
      assert_equal 1, item.content_revisions.where(event: "scheduled_publish").count
      first = item.first_published_at
      change(item, "unpublish")
      refute PublishContentJob.new.perform(item.id, version)
      assert_equal "draft", item.reload.status
      change(item, "publish")
      assert_equal first, item.first_published_at
    end
    end
  end
  test "recurring sweep catches due work and demotion cancels scheduled authority" do
    item = draft
    due = 2.hours.from_now.change(sec: 0)
    change(item, "schedule", attributes: { schedule_local: due.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M") })
    version = item.lock_version
    Identity::ManageUsers.change_role!(actor: @owner, user: @editor, role: "author")
    with_controlled_security_clock do
    with_qualified_utc(due + 1.second) do
      assert_enqueued_with(job: PublishContentJob, args: [ item.id, version ]) { PublishDueContentJob.perform_now }
      assert PublishContentJob.new.perform(item.id, version)
      assert_equal "draft", item.reload.status
      assert_nil item.published_snapshot
      assert_equal 1, item.content_revisions.where(event: "schedule_cancelled").count
    end
    end
  end
  test "stale native snapshot cannot authorize a demoted publisher" do
    item = draft
    ready = Queue.new
    proceed = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Content.transaction do
          User.find(@editor.id)
          Content.find(item.id)
          ready << true
          proceed.pop
          change(item, "publish", actor: @editor)
          :published
        end
      end
    rescue Identity::Capabilities::Denied
      :denied
    end
    ready.pop
    Identity::ManageUsers.change_role!(actor: @owner, user: @editor, role: "author")
    proceed << true
    assert thread.join(20)
    assert_equal :denied, thread.value
    assert_equal "draft", item.reload.status
  ensure
    thread&.kill if thread&.alive?
  end
  test "preview credential is hashed snapshot-isolated and revoked by role version" do
    item = draft
    record, token = Editorial::Previews.issue!(actor: @editor, content: item)
    refute_equal token, record.token_digest
    assert_equal item.body, record.snapshot["body"]
    change(item, attributes: { body: "<p>Later edit</p>" })
    refute_equal item.body, record.reload.snapshot["body"]
    assert_raises(ActiveRecord::RecordNotFound) { Editorial::Previews.resolve!(actor: @author, id: record.id, token: token) }
    Identity::ManageUsers.change_role!(actor: @owner, user: @editor, role: "author")
    assert_raises(ActiveRecord::RecordNotFound) { Editorial::Previews.resolve!(actor: @editor.reload, id: record.id, token: token) }
  end

  test "author changes cancel an approved schedule rather than publishing unreviewed edits" do
    item = draft
    due = 2.hours.from_now.change(sec: 0)
    change(item, "schedule", attributes: { schedule_local: due.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M") })
    scheduled_version = item.lock_version
    change(item, actor: @author, attributes: { body: "<p>Unapproved change</p>" })
    assert_equal "draft", item.status
    assert_nil item.scheduled_at
    with_qualified_utc(due + 1.second) do
      refute PublishContentJob.new.perform(item.id, scheduled_version)
      PublishDueContentJob.perform_now
      assert_equal "draft", item.reload.status
      assert_nil item.published_snapshot
    end
  end
end
