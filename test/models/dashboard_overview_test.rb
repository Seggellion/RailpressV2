require "test_helper"
require_relative "../support/official_news_test_support"
require_relative "../support/administration_test_support"
require "open3"
class DashboardOverviewTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include OfficialNewsTestSupport
  include AdministrationTestSupport
  setup { install_site! }
  test "four roles receive scoped SQL counts drafts media and activity without privileged operational leakage" do
    author=create_account("author")
    editor=create_account("editor")
    admin=create_account("administrator")
    other=create_account("author", "otherauthor")
    mine=Editorial::Workflow.create!(actor: author, kind: "Page", attributes: { "title"=>"Own private draft", "visibility"=>"private" })
    Editorial::Workflow.create!(actor: other, kind: "Post", attributes: { "title"=>"Other private draft" })
    public_post=news_post
    overview=Dashboard::Overview.new(actor: author)
    assert_equal 1, overview.count("Page", "draft")
    assert_equal 0, overview.count("Post", "draft")
    assert_equal 0, overview.public_count("Post")
    assert_equal [ mine.id ], overview.drafts.map(&:id)
    assert_nil overview.operations
    refute_includes overview.activity.map(&:subject_id), public_post.id
    [ editor, admin, @owner ].each do |actor|
      view=Dashboard::Overview.new(actor: actor)
      assert_equal 1, view.count("Post", "draft")
      assert_equal 1, view.public_count("Post")
      assert_equal 2, view.drafts.length
      assert_equal({ "ready"=>0, "bytes"=>0, "unavailable"=>0 }, view.media)
    end
    assert_nil Dashboard::Overview.new(actor: editor).operations
    assert_nil Dashboard::Overview.new(actor: admin).operations["release"]
    assert_equal "DISABLED", overview.news["state"]
  end
  test "publication and withdrawal counts use durable editorial authority across wall rollback" do
    post=news_post
    before=Time.current
    travel_to(before-5.seconds) do
        held=Dashboard::Overview.new(actor: @owner)
        assert_equal 1, held.public_count("Post")
        assert held.clock_held
      assert post.reload.publicly_visible?
    end
    Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "unpublish")
    assert_equal 0, Dashboard::Overview.new(actor: @owner).public_count("Post")
    assert_equal 1, Dashboard::Overview.new(actor: @owner).count("Post", "draft")
  end
  test "all editorial state counts distinguish approved public private scheduled pending and trashed content" do
    make=->(title, kind = "Post", visibility = "public") { Editorial::Workflow.create!(actor: @owner, kind: kind, attributes: { "title"=>title, "visibility"=>visibility }) }
    draft=make.call("Only draft")
    pending=make.call("Pending review")
    Editorial::Workflow.update!(actor: @owner, content: pending, expected_version: pending.lock_version, event: "submit")
    scheduled=make.call("Scheduled later")
    due=(Time.current+1.day).in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M")
    Editorial::Workflow.update!(actor: @owner, content: scheduled, expected_version: scheduled.lock_version, event: "schedule", attributes: { "schedule_local"=>due })
    private_post=make.call("Private publication", "Post", "private")
    Editorial::Workflow.update!(actor: @owner, content: private_post, expected_version: private_post.lock_version, event: "publish")
    trash=make.call("Removed draft")
    Editorial::Workflow.update!(actor: @owner, content: trash, expected_version: trash.lock_version, event: "trash")
    public_post=news_post
    page=make.call("Published page", "Page")
    Editorial::Workflow.update!(actor: @owner, content: page, expected_version: page.lock_version, event: "publish")
    queries=[]
    observer=->(*args) { payload=args.last;queries<<payload[:sql] unless payload[:cached] }
    view=nil
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { view=Dashboard::Overview.new(actor: @owner) }
    assert_equal({ "draft"=>1, "pending"=>1, "scheduled"=>1, "published"=>2, "trashed"=>1 }, Content::STATES.to_h { |state|[ state, view.count("Post", state) ] })
    assert_equal 1, view.public_count("Post")
    assert_equal 1, view.public_count("Page")
    assert_equal [ draft.id, pending.id, scheduled.id ].sort, view.drafts.map(&:id).sort
    assert queries.any? { |sql|sql.match?(/COUNT\(/i) && sql.match?(/GROUP BY/i) }
    assert queries.any? { |sql|sql.match?(/SUM\(/i) }
    assert queries.any? { |sql|sql.include?("contents") && sql.include?("LIMIT") }
    Editorial::Workflow.update!(actor: @owner, content: public_post, expected_version: public_post.lock_version, event: "unpublish")
    assert_equal 0, Dashboard::Overview.new(actor: @owner).public_count("Post")
  end
  test "quick draft is private valid audited and immutable across duplicate stale or changed submissions" do
    key=SecureRandom.uuid
    args={ actor: @owner, request_key: key, expected_version: 0, kind: "Post", title: "A real quick draft", body: "<p>Saved content</p><script>bad()</script>" }
    item=Dashboard::QuickDraft.call(**args)
    assert_equal "private", item.visibility
    assert_equal "draft", item.status
    refute item.publicly_visible?
    refute_includes item.body, "<script>"
    assert_equal item.id, Dashboard::QuickDraft.call(**args).id
    assert_equal 1, Content.count
    assert_equal 1, ContentRevision.count
    assert_equal 1, ActivityEvent.where(action: "content.create").count
    Editorial::Workflow.update!(actor: @owner, content: item, expected_version: item.lock_version, attributes: { "title"=>"Later editorial title" })
    assert_equal "Later editorial title", Dashboard::QuickDraft.call(**args).title
    assert_raises(Editorial::Workflow::Conflict) { Dashboard::QuickDraft.call(**args.merge(title: "Changed reused submission")) }
    assert_raises(Editorial::Workflow::Invalid) { Dashboard::QuickDraft.call(**args.merge(expected_version: 1)) }
    assert_raises(ActiveRecord::RecordInvalid) { Dashboard::QuickDraft.call(**args.merge(request_key: SecureRandom.uuid, title: "")) }
    assert_equal 1, DashboardDraftSubmission.count
  end
  test "simultaneous quick drafts with identical submission commit exactly once" do
    key=SecureRandom.uuid;gate=Queue.new;errors=Queue.new;ids=Queue.new
    workers=2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          actor=User.find(@owner.id);gate.pop
          ids<<Dashboard::QuickDraft.call(actor: actor, request_key: key, expected_version: 0, kind: "Page", title: "Concurrent draft", body: "").id
        rescue StandardError=>error
          errors<<error
        end
      end
    end
    2.times { gate<<true };workers.each(&:join)
    assert errors.empty?, errors.size.to_s
    assert_equal 1, ids.size.times.map { ids.pop }.uniq.length
    assert_equal 1, Content.count
    assert_equal 1, DashboardDraftSubmission.count
  end
  test "measured zero available storage is actionable rather than a green capacity badge" do
    success=Object.new
    success.define_singleton_method(:success?) { true }
    with_method(Open3, :capture2, ->(*) { [ "Filesystem 1B-blocks Used Available Capacity Mounted
fixture 100 100 0 100% /
", success ]}) do
      result=Readiness::Probes.storage_capacity
      assert_equal "ACTION REQUIRED", result["state"]
      assert_includes result["detail"], "0 bytes"
    end
  end
  test "corrupt stale and absent readiness or broken theme evidence never creates healthy dashboard status" do
    summary=Dashboard::Overview.new(actor: @owner).operations
    assert_equal "UNKNOWN", summary["readiness_state"]
    assert_equal "UNKNOWN", summary["worker"]
    assert_nil summary["theme"]
    run=ReadinessRun.create!(site: Site.first, actor: @owner, auth_version: @owner.auth_version, state: "complete", observed_at: Time.current,
      fingerprint: Readiness::Assessment.fingerprint(Site.first), findings: [ { "key"=>"database", "state"=>"HEALTHY", "detail"=>"Checked locally." } ])
    assert_equal "DATED OBSERVATION", Dashboard::Overview.new(actor: @owner).operations["readiness_state"]
    run.update_columns(findings: { "unexpected"=>"corruption" })
    assert_empty Dashboard::Overview.new(actor: @owner).operations["findings"]
    run.update_columns(findings: [], observed_at: 10.minutes.ago)
    assert_equal "STALE / UNKNOWN", Dashboard::Overview.new(actor: @owner).operations["readiness_state"]
  end
end
