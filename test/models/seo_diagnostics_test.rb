require "test_helper"
require_relative "../support/seo_test_support"
class SeoDiagnosticsTest < ActiveSupport::TestCase
  include SeoTestSupport
  test "concurrent starts create one active run and one queued job on real adapters" do
    public_content
    results=parallel_results(2) { Seo::Diagnostics.start!(actor: User.find(@owner.id)).id }
    assert_equal 1, results.uniq.length
    assert_equal 1, Seo::DiagnosticRun.where(active_key: "site").count
    assert_equal 2, Seo::DiagnosticTarget.count
    assert_equal 1, enqueued_jobs.count { |job| job[:job]==SeoDiagnosticJob }
    run=Seo::DiagnosticRun.find(results.first)
    assert_equal 2, run.summary["inventory_count"]
  end
  test "long UTF8 URL uses portable digest uniqueness with JSON persistence" do
    run=Seo::Diagnostics.start!(actor: @owner)
    url=site.canonical_origin+"/"+"日本語"*450
    target=run.diagnostic_targets.create!(url: url, family: "page", position: 0, result: { "日本語"=>[ "value", { "safe"=>true } ] })
    assert_equal Digest::SHA256.hexdigest(url), target.reload.url_digest
    assert_equal true, target.result["日本語"].last["safe"]
    assert_raises(ActiveRecord::RecordNotUnique) { run.diagnostic_targets.create!(url: url, family: "page", position: 1, result: {}) }
    assert_raises(ActiveRecord::StatementInvalid) { run.update_columns(status: "running", active_key: nil) }
  end
  test "duplicate worker delivery is idempotent and offline findings are genuine" do
    public_content
    run=Seo::Diagnostics.start!(actor: @owner)
    Seo::Diagnostics.execute!(run.id)
    assert_equal "completed", run.reload.status, run.summary.inspect
    assert_nil run.active_key
    assert_equal 2, run.summary["checked"]
    assert_empty run.summary["codes"]
    before=run.finished_at
    Seo::Diagnostics.execute!(run.id)
    assert_equal before, run.reload.finished_at
    assert run.diagnostic_targets.all? { |target| target.result["source"]=="offline_policy" && target.checked_at }
  end
  test "current authority policy origin and operator gates cancel old jobs" do
    public_content
    run=Seo::Diagnostics.start!(actor: @owner)
    site.update!(indexing_enabled: false)
    Seo::Diagnostics.execute!(run.id)
    assert_equal "cancelled", run.reload.status
    assert_equal 0, run.diagnostic_targets.where.not(checked_at: nil).count
    second=create_account("owner", "second-owner")
    fresh=Seo::Diagnostics.start!(actor: @owner)
    Identity::ManageUsers.change_role!(actor: second, user: @owner, role: "editor")
    Seo::Diagnostics.execute!(fresh.id)
    assert_equal "cancelled", fresh.reload.status
    assert_raises(Identity::Capabilities::Denied) { Seo::Diagnostics.start!(actor: @owner) }
    assert_raises(Seo::Diagnostics::Invalid) { Seo::Diagnostics.start!(actor: second, mode: "http") }
  end
  test "stale native owner snapshot cannot start diagnostics after demotion" do
    second=create_account("owner", "second-owner")
    ready=Queue.new;proceed=Queue.new
    thread=Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Site.transaction do
          User.find(@owner.id);ready<<true;proceed.pop
          Seo::Diagnostics.start!(actor: @owner)
          :started
        end
      end
    rescue Identity::Capabilities::Denied
      :denied
    end
    ready.pop
    Identity::ManageUsers.change_role!(actor: second, user: @owner, role: "editor")
    proceed<<true
    assert thread.join(20)
    assert_equal :denied, thread.value
    assert_equal 0, Seo::DiagnosticRun.count
  ensure
    thread&.kill if thread&.alive?
  end
  test "queue cache and stale-run failures stay isolated from publication" do
    public_content
    with_method(SeoDiagnosticJob, :perform_later, ->(*) { raise IOError, "synthetic queue outage" }) do
      run=Seo::Diagnostics.start!(actor: @owner)
      assert_equal "failed", run.reload.status
      assert_includes run.summary["codes"], "queue_unavailable"
    end
    run=Seo::Diagnostics.start!(actor: @owner)
    run.update!(updated_at: 11.minutes.ago)
    replacement=Seo::Diagnostics.start!(actor: @owner)
    refute_equal run.id, replacement.id
    assert_equal "failed", run.reload.status
    assert_equal 1, Seo::DiagnosticRun.where(active_key: "site").count
    item=draft(slug: "outage-independent")
    change(item, "publish")
    assert_includes sitemap_urls, site.canonical_origin+"/blog/outage-independent"
  end
  test "redirect uniqueness and foreign keys are backed by native constraints" do
    item=public_content
    row=Redirect.create!(source_path: "/old-page", target_content: item)
    assert_raises(ActiveRecord::RecordNotUnique) { Redirect.create!(source_path: row.source_path, target_content: item) }
    assert_raises(ActiveRecord::InvalidForeignKey) { row.update_columns(target_content_id: 999999999) }
  end
  test "explicit HTTP mode persists guarded response findings without real external requests" do
    old=ENV["RAILPRESS_SEO_HTTP_ENABLED"]
    ENV["RAILPRESS_SEO_HTTP_ENABLED"]="1"
    site.update!(canonical_origin: "https://publisher.example.invalid")
    public_content
    run=Seo::Diagnostics.start!(actor: @owner, mode: "http")
    seen=[]
    client=Object.new
    client.define_singleton_method(:get) do |uri:, ip_address:|
      seen<<ip_address
      graph=JSON.generate("@graph"=>[ { "@type"=>"WebPage", "url"=>uri.to_s } ])
      html=%(<html><head><meta name="robots" content="index, follow"><link rel="canonical" href="#{uri}"><script type="application/ld+json">#{graph}</script></head></html>)
      Seo::NetHttpClient::Response.new(status: 200, headers: { "content-type"=>[ "text/html" ] }, body: html)
    end
    Seo::Diagnostics.execute!(run.id, client: client, resolver: ->(_) { [ "8.8.8.8" ] })
    assert_equal "completed", run.reload.status
    assert_empty run.summary["codes"]
    assert_equal [ "8.8.8.8", "8.8.8.8" ], seen
    assert run.diagnostic_targets.all? { |target|target.result["http_status"]==200 }
  ensure
    ENV["RAILPRESS_SEO_HTTP_ENABLED"]=old
  end
  test "retained diagnostic attribution blocks account deletion cleanly" do
    second=create_account("owner", "second-owner")
    Seo::Diagnostics.start!(actor: @owner)
    assert_raises(ActiveRecord::RecordNotDestroyed) { Identity::ManageUsers.remove!(actor: second, user: @owner) }
    assert User.exists?(@owner.id)
    assert_equal @owner.id, site.owner_id
  end
end
