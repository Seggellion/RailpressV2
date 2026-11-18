require "test_helper"
require_relative "../support/seo_test_support"
require_relative "../support/security_clock_test_support"

class ClockPublicationRaceTest < ActionDispatch::IntegrationTest
  include SeoTestSupport
  include SecurityClockTestSupport

  test "concurrent publish and withdrawal agree across public consumers during clock rollback" do
    asset = upload_media
    item = change(draft(slug: "racing-public", featured_media_id: asset.id), "publish")
    matrix = []
    [ 1, 2, 3, 5 ].each do |seconds|
      change(item.reload, "publish") unless item.reload.publicly_visible?
      version = item.lock_version
      cache = ActiveSupport::Cache::MemoryStore.new
      Seo::SitemapCache.fetch(site: site, cache: cache)
      outcomes = nil
      travel(-seconds.seconds) do
        outcomes = parallel_results(2) do |index|
          event = index.zero? ? "publish" : "unpublish"
          Editorial::Workflow.update!(actor: User.find(@editor.id), content: Content.find(item.id), expected_version: version, event: event)
          event
        rescue Editorial::Workflow::Conflict
          "conflict"
        end
        assert_equal 1, outcomes.count("conflict")
        shown = outcomes.include?("publish")
        assert_equal shown, item.reload.publicly_visible?
        assert_equal shown, Content.publicly_visible.exists?(item.id)
        assert_equal shown, !!Seo::Policy.visible?(item)
        get "/blog/racing-public"; assert_equal shown ? 200 : 404, response.status
        assert_equal shown, !!Navigation::Destinations.resolve({ "kind" => "Post", "content_id" => item.id }, site)
        get public_media_file_path(content_id: item.id, public_id: asset.public_id, variant: "display")
        assert_equal shown ? 200 : 404, response.status
        export = Portability::Export.call(actor: @owner)
        assert_equal shown ? 1 : 0, export["content"].length
        assert_equal shown ? 1 : 0, export["media"].length
        assert_equal shown, Seo::SitemapCache.fetch(site: site, cache: cache).xml.include?("/blog/racing-public")
        matrix << { rollback_seconds: seconds, outcomes: outcomes.sort, public: shown, media: shown, export: shown, sitemap: shown }
      end
    end
    clock_evidence("concurrent-publication-withdrawal", matrix)
  end

  test "sitemap retention expires by elapsed time even if wall time moves backward" do
    public_content
    cache = ActiveSupport::Cache::MemoryStore.new
    ticks = 100.0
    replacing_method(Railpress::SecurityClock, :elapsed, -> { ticks }) do
      initial = Seo::SitemapCache.fetch(site: site, cache: cache)
      travel(-5.seconds) do
        ticks += 59
        assert_equal initial.generated_elapsed, Seo::SitemapCache.fetch(site: site, cache: cache).generated_elapsed
        ticks += 2
        refreshed = Seo::SitemapCache.fetch(site: site, cache: cache)
        assert_equal 161.0, refreshed.generated_elapsed
        assert_equal initial.xml, refreshed.xml
        assert_equal initial.etag, refreshed.etag
      end
      replacing_method(Railpress::SecurityClock, :boot_domain, -> { "different-synthetic-boot" }) do
        assert_equal "different-synthetic-boot", Seo::SitemapCache.fetch(site: site, cache: cache).clock_domain
      end
    end
  end
end
