require "test_helper"
require_relative "../support/security_clock_test_support"
require_relative "../support/seo_test_support"
class QualificationVisibilityTest < ActionDispatch::IntegrationTest
  include SecurityClockTestSupport
  include SeoTestSupport
  test "committed public rows persist through controlled clock rollback without promoting private content" do
    base = Time.current.utc.change(usec: 0)
    13.times do |index|
      travel_to(base + index * 0.05, with_usec: true) { public_content(slug: "clock-#{index}", title: "APPROVED CLOCK #{index}") }
    end
    travel_to(base + 2, with_usec: true) do
      @draft = draft(slug: "clock-draft", title: "DRAFT CLOCK SECRET")
      @private = public_content(slug: "clock-private", title: "PRIVATE CLOCK SECRET", visibility: "private")
      @scheduled = draft(slug: "clock-scheduled", title: "SCHEDULE CLOCK SECRET")
      change(@scheduled, "schedule", attributes: { schedule_local: 2.hours.from_now.in_time_zone(site.timezone).strftime("%Y-%m-%dT%H:%M") })
    end
    matrix = []
    [ [ 2.0, 13 ], [ 0.425, 13 ], [ 0.125, 13 ], [ -0.1, 13 ], [ -5.0, 13 ], [ 2.0, 13 ] ].each do |offset, visible|
      travel_to(base + offset, with_usec: true) do
        now = Time.current
        get "/blog"
        assert_response :ok
        assert_select "article", count: [ visible, 12 ].min
        refute_match(/DRAFT CLOCK SECRET|PRIVATE CLOCK SECRET|SCHEDULE CLOCK SECRET/, response.body)
        get "/blog?page=2"
        assert_equal visible == 13 ? 200 : 404, response.status
        get "/search?q=APPROVED"
        assert_response :ok
        assert_select "article", count: [ visible, 12 ].min
        refute_match(/DRAFT CLOCK SECRET|PRIVATE CLOCK SECRET|SCHEDULE CLOCK SECRET/, response.body)
        [ @draft, @private, @scheduled ].each do |item|
          get "/blog/#{item.slug}"
          assert_response :not_found
        end
        matrix << { app_time: now.iso8601(6), offset: offset, eligible: visible, sql_visible_ids: Post.publicly_visible.order(:id).pluck(:id), page_two_status: visible == 13 ? 200 : 404 }
      end
    end
    File.write(Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-clock-visibility-proof.json"), JSON.pretty_generate(scope: "only Ruby test application clock controlled;host clock untouched;causal reproduction not historical attribution", matrix: matrix) + "\n")
  end
  test "wall changes cannot publish scheduled content early or defeat withdrawal generation" do
    base = Time.current.utc.change(usec: 0)
    item = nil
    travel_to(base) do
      item = draft(slug: "clock-schedule")
      change(item, "schedule", attributes: { schedule_local: 2.hours.from_now.in_time_zone(site.timezone).strftime("%Y-%m-%dT%H:%M") })
    end
    travel_to(base - 1.hour) do
      refute PublishContentJob.perform_now(item.id, item.lock_version)
      get "/blog/clock-schedule"; assert_response :not_found
    end
    with_qualified_utc(base + 3.hours) do
      assert PublishContentJob.perform_now(item.id, item.lock_version)
      assert_equal "published", item.reload.status
      assert_includes sitemap_urls, site.canonical_origin + "/blog/clock-schedule"
      generation = site.seo_generation
      change(item, "unpublish")
      assert_operator site.reload.seo_generation, :>, generation
      assert_empty sitemap_urls
    end
    travel_to(base + 1.hour) do
      get "/blog/clock-schedule"; assert_response :not_found
      assert_empty sitemap_urls
      assert_nil item.reload.published_snapshot
    end
  end
  test "sitemap cache retains committed publication through clock rollback without a generation change" do
    base = Time.current.utc.change(usec: 0)
    cache = ActiveSupport::Cache::MemoryStore.new
    url = site.canonical_origin + "/blog/clock-cache"
    initial = nil
    travel_to(base, with_usec: true) do
      public_content(slug: "clock-cache")
      initial = Seo::SitemapCache.fetch(site: site, cache: cache)
      assert_includes initial.xml, url
    end
    travel_to(base - 0.5, with_usec: true) do
      assert_equal 2, Seo::UrlInventory.call(site: site).length
      observed = Seo::SitemapCache.fetch(site: site, cache: cache)
      File.write(Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-temporal-cache-proof.json"), JSON.pretty_generate(scope: "controlled Ruby clock only;unchanged DB generation", rollback_inventory_count: Seo::UrlInventory.call(site: site).length, cached_count: observed.count, cached_url_exposed: observed.xml.include?(url), prior_payload_reused: observed.equal?(initial)) + "
")
      assert_includes observed.xml, url, "A backward clock must not withdraw committed publication from the sitemap"
    end
    travel_to(base + 0.1, with_usec: true) do
      recovered = Seo::SitemapCache.fetch(site: site, cache: cache)
      assert_includes recovered.xml, url, "Clock recovery must not retain a stale empty sitemap until TTL"
    end
  end
end
