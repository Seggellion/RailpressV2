require "test_helper"
require_relative "../support/administration_test_support"
class AdministrationObservabilityTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include AdministrationTestSupport
  setup do
    install_site!
    @admin = create_account("administrator")
    @editor = create_account("editor")
    @author = create_account("author")
    @other = create_account("author", "otherauthor")
  end
  def draft(author = @author)
    Editorial::Workflow.create!(actor: author, kind: "Post", attributes: { "title" => "Private working title", "slug" => "working-#{SecureRandom.hex(4)}" })
  end
  test "declarative leaves are real protected routes with exact role subsets" do
    Administration::Navigation.validate!
    owner = Administration::Navigation.for(@owner).flat_map(&:last).map(&:key)
    assert_equal %w[dashboard pages posts categories tags media themes customize menus seo users settings accounts privacy updates modules official_news portability readiness activity], owner
    expected = { @admin => %w[dashboard pages posts categories tags media menus readiness activity],
      @editor => %w[dashboard pages posts categories tags media activity],
      @author => %w[dashboard pages posts media activity] }
    expected.each { |actor, keys| assert_equal keys, Administration::Navigation.for(actor).flat_map(&:last).map(&:key) }
  end
  test "editorial activity is immutable scoped and does not carry content or credential fields" do
    mine = draft
    theirs = draft(@other)
    event = ActivityEvent.find_by!(action: "content.create", subject_id: mine.id)
    assert_equal @author.id, event.subject_owner_id
    assert_equal({ "content_kind" => "Post", "state" => "draft", "revision" => 1 }, event.details)
    refute_includes Activity::Recorder.scope_for(@author).pluck(:id), ActivityEvent.find_by!(action: "content.create", subject_id: theirs.id).id
    assert_includes Activity::Recorder.scope_for(@editor).pluck(:id), event.id
    private_event = Activity::Recorder.record!(actor: @owner, action: "identity.site_updated", subject: Site.first,
      details: { password: "never-store-password", token: "secret", email: "private@example.invalid", reason: "https://secret.invalid", state: { "password" => "nested" } })
    assert_empty private_event.details
    [ @admin, @editor, @author ].each { |actor| refute_includes Activity::Recorder.scope_for(actor).pluck(:id), private_event.id }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(details: {}) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
    refute_includes ActivityEvent.all.to_json, "Private working title"
  end
  test "failed audit rolls back content and no successful revision is committed" do
    before = [ Content.count, ContentRevision.count, ActivityEvent.count ]
    with_method(ActivityEvent, :create!, ->(**) { raise ActiveRecord::StatementInvalid, "synthetic refusal" }) do
      assert_raises(Activity::Recorder::Unavailable) { draft }
    end
    assert_equal before, [ Content.count, ContentRevision.count, ActivityEvent.count ]
  end
  test "bounded retention prunes expired and overflow events" do
    site = Site.first
    ActivityEvent.delete_all
    rows = 1005.times.map { |i| { site_id: site.id, actor_name: "system", category: "operations", action: "readiness.completed", outcome: "succeeded", details: {}, created_at: i < 3 ? 100.days.ago : Time.current } }
    ActivityEvent.insert_all!(rows)
    site.with_lock { Activity::Recorder.prune!(site) }
    assert_equal 1000, ActivityEvent.count
    refute ActivityEvent.where("created_at < ?", 90.days.ago).exists?
    assert_operator ActivityEvent.minimum(:id), :>, 3
  end
  test "authorship transfer is explicit owner-only revisioned and does not edit approved snapshots" do
    item = draft
    Editorial::Workflow.update!(actor: @owner, content: item, expected_version: item.lock_version, event: "publish")
    snapshot = item.published_snapshot.deep_dup
    %w[administrator editor author].each do |role|
      actor = User.find_by!(role: role)
      assert_raises(Identity::Capabilities::Denied) { Editorial::Authorship.transfer!(actor: actor, content: item, author_id: @other.id, version: item.lock_version) }
    end
    old_version = item.lock_version
    Editorial::Authorship.transfer!(actor: @owner, content: item, author_id: @other.id, version: old_version)
    assert_equal @other.id, item.reload.author_id
    assert_equal snapshot, item.published_snapshot
    assert_equal "reassign", item.content_revisions.order(:number).last.event
    assert_raises(Editorial::Workflow::Conflict) { Editorial::Authorship.transfer!(actor: @owner, content: item, author_id: @author.id, version: old_version) }
    assert_raises(Identity::Capabilities::Denied) { Editorial::Workflow.update!(actor: @author, content: item, expected_version: item.lock_version) }
    revision = item.content_revisions.find_by!(event: "create")
    Editorial::Workflow.update!(actor: @owner, content: item, expected_version: item.lock_version, event: "restore_revision", revision_id: revision.id)
    assert_equal @other.id, item.reload.author_id
    assert_nil item.published_snapshot
  end
  test "scheduled authorship transfer cancels prior approval" do
    item = draft
    Editorial::Workflow.update!(actor: @owner, content: item, expected_version: item.lock_version, event: "schedule",
      attributes: { "schedule_local" => 2.days.from_now.in_time_zone("America/Vancouver").strftime("%Y-%m-%dT%H:%M") })
    Editorial::Authorship.transfer!(actor: @owner, content: item, author_id: @other.id, version: item.lock_version)
    assert_equal "draft", item.reload.status
    assert_nil item.scheduled_at
    assert_nil item.published_snapshot
  end
  test "concurrent authorship transfer admits exactly one version and records no losing changes" do
    item = draft
    version = item.lock_version
    results = parallel_results(2) do |i|
      begin
        Editorial::Authorship.transfer!(actor: User.find(@owner.id), content: Content.find(item.id), author_id: [ @owner.id, @other.id ][i], version: version)
        :saved
      rescue Editorial::Workflow::Conflict
        :conflict
      end
    end
    assert_equal [ :conflict, :saved ], results.sort
    assert_equal 2, item.content_revisions.count
  end
  test "readiness is deduplicated and completion has truthful stale future and changed-policy semantics" do
    first = Readiness::Assessment.request!(actor: @owner)
    assert_equal first.id, Readiness::Assessment.request!(actor: @admin).id
    assert_equal 1, ReadinessRun.count
    cells = [ Readiness::Probes.cell("backup_restore", "UNKNOWN", "No restore proof") ]
    with_method(Readiness::Probes, :call, cells) { AssessReadinessJob.perform_now(first.id) }
    assert_equal "complete", first.reload.state
    assert_nil first.active_slot
    assert Readiness::Assessment.current?(first)
    assert_equal "UNKNOWN", first.findings.first["state"]
    assert_equal "UNKNOWN", first.findings.last["state"]
    assert_equal 2, first.findings.size
    assert_not Readiness::Assessment.current?(first, at: first.observed_at - 1.second)
    assert_not Readiness::Assessment.current?(first, at: first.observed_at + 4.minutes)
    Site.first.update!(tagline: "Changed configuration")
    assert_not Readiness::Assessment.current?(first)
  end
  test "readiness concurrency keeps one active assessment and cancellation is optimistic" do
    results = parallel_results(2) { Readiness::Assessment.request!(actor: User.find(@owner.id)).id }
    assert_equal 1, results.uniq.size
    run = ReadinessRun.find(results.first)
    assert_raises(Readiness::Assessment::Conflict) { Readiness::Assessment.cancel!(actor: @admin, run: run, version: 999) }
    assert_equal "pending", run.reload.state
    Readiness::Assessment.cancel!(actor: @admin, run: run, version: run.lock_version)
    AssessReadinessJob.perform_now(run.id)
    assert_equal "cancelled", run.reload.state
    refute_equal run.id, Readiness::Assessment.request!(actor: @owner).id
  end
  test "queued readiness rechecks role and auth version before probing" do
    run = Readiness::Assessment.request!(actor: @admin)
    Identity::ManageUsers.change_role!(actor: @owner, user: @admin, role: "editor")
    with_method(Readiness::Probes, :call, ->(*) { flunk "revoked job ran probes" }) { AssessReadinessJob.perform_now(run.id) }
    assert_equal "cancelled", run.reload.state
    assert_equal "authority_changed", run.failure_code
    assert_empty run.findings
    [ @editor, @author ].each { |actor| assert_raises(Identity::Capabilities::Denied) { Readiness::Assessment.request!(actor: actor) } }
  end
  test "readiness captures missing local theme and no-service observations without remote I/O" do
    cells = Readiness::Probes.call(Site.first).index_by { |cell| cell["key"] }
    assert_equal "HEALTHY", cells.fetch("database")["state"]
    assert_equal "ACTION REQUIRED", cells.fetch("theme")["state"]
    assert_equal "ACTION REQUIRED", cells.fetch("mail")["state"]
    assert_equal "HEALTHY", cells.fetch("storage")["state"]
    assert_equal "ACTION REQUIRED", cells.fetch("menus")["state"]
    assert_equal "UNKNOWN", cells.fetch("backup_restore")["state"]
    assert_equal "UNSUPPORTED", cells.fetch("updates")["state"]
    assert_equal "DEGRADED", cells.fetch("qualification")["state"]
    assert_includes %w[UNKNOWN DEGRADED], cells.fetch("worker")["state"]
    with_method(MediaLibrary::Storage, :ensure_private!, -> { raise IOError, "secret-location" }) do
      failed = Readiness::Probes.call(Site.first).find { |cell| cell["key"] == "storage" }
      assert_equal "ACTION REQUIRED", failed["state"]
      refute_includes failed.to_json, "secret-location"
    end
  end
  test "assessment failure is explicit and duplicate delivery does not rerun probes" do
    run = Readiness::Assessment.request!(actor: @owner)
    with_method(Readiness::Probes, :call, ->(*) { raise IOError, "secret-endpoint" }) { AssessReadinessJob.perform_now(run.id) }
    assert_equal "failed", run.reload.state
    assert_equal "assessment_unavailable", run.failure_code
    assert_nil run.active_slot
    with_method(Readiness::Probes, :call, ->(*) { flunk "duplicate executed" }) { AssessReadinessJob.perform_now(run.id) }
    refute_includes run.to_json, "secret-endpoint"
  end
  test "origin readiness reports configured disagreement without claiming remote TLS availability" do
    site = Site.first
    assert_equal "UNKNOWN", Readiness::Probes.origin(site, configured_origin: nil)["state"]
    assert_equal "UNKNOWN", Readiness::Probes.origin(site, configured_origin: site.canonical_origin)["state"]
    assert_equal "ACTION REQUIRED", Readiness::Probes.origin(site, configured_origin: "https://other.example.invalid")["state"]
    invalid = Readiness::Probes.check("origin_tls") { Readiness::Probes.origin(site, configured_origin: "https://user:private-origin-secret@example.invalid") }
    assert_equal "ACTION REQUIRED", invalid["state"]
    refute_includes invalid.to_json, "private-origin-secret"
  end
end
