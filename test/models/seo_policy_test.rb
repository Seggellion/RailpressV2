require "test_helper"
require_relative "../support/seo_test_support"
class SeoPolicyTest < ActiveSupport::TestCase
  include SeoTestSupport
  test "site origins and generated canonicals reject unsafe paths and origins" do
    %w[http://example.invalid https://user:pass@example.invalid https://example.invalid/path https://example.invalid?x=y https://example.invalid/#fragment].each do |value|
      assert_raises(Seo::SiteOrigin::Invalid) { Seo::SiteOrigin.new(value) }
    end
    assert_equal "https://example.invalid", Seo::SiteOrigin.new("https://EXAMPLE.invalid:443").to_s
    canonical=Seo::CanonicalUrl.new(origin: site.canonical_origin)
    [ "//evil.invalid", "/../admin", "/good\\evil", "https://evil.invalid", "/safe?canonical=x" ].each do |value|
      assert_raises(Seo::SiteOrigin::Invalid) { canonical.call(value) }
    end
    assert_equal site.canonical_origin+"/blog?page=2", canonical.call("/blog", query: { page: 2 })
  end
  test "public lastmod generation and cache stay unchanged by unapproved draft edits" do
    item=public_content
    before=site.seo_generation
    xml=Seo::SitemapCache.fetch(site: site).xml
    travel 2.seconds do
      change(item, attributes: { body: "<p>Private edit</p>" })
      assert_equal before, site.seo_generation
      assert_equal xml, Seo::SitemapCache.fetch(site: site).xml
      change(item, "publish")
      assert_operator site.seo_generation, :>, before
      refute_equal xml, Seo::SitemapCache.fetch(site: site).xml
    end
  end
  test "rename redirects follow identity through repeated renames and cannot be hijacked" do
    item=public_content(slug: "old")
    change(item, "unpublish")
    change(item, "publish", attributes: { slug: "middle" })
    change(item, "unpublish")
    change(item, "publish", attributes: { slug: "latest" })
    assert_equal "/blog/latest", Seo::Redirects.resolve("/blog/old", site)
    assert_equal "/blog/latest", Seo::Redirects.resolve("/blog/middle", site)
    assert_raises(ActiveRecord::RecordInvalid) { draft(slug: "old") }
    change(item, "unpublish")
    assert_nil Seo::Redirects.resolve("/blog/old", site)
    change(item, "publish", attributes: { slug: "old" })
    assert_nil Seo::Redirects.resolve("/blog/old", site)
    assert_equal "/blog/old", Seo::Redirects.resolve("/blog/latest", site)
    assert_raises(ActiveRecord::RecordInvalid) { Redirect.create!(source_path: "//evil.invalid", target_content: item) }
    assert_raises(ActiveRecord::RecordInvalid) { Redirect.create!(source_path: "/admin", target_content: item) }
  end
  test "sitemap comparison detects missing, duplicate and wrong public modification dates" do
    public_content
    entries = Seo::UrlInventory.call(site: site)
    first = entries.first
    stale = first.with(last_modified: first.last_modified - 1.day)
    xml = Seo::SitemapRenderer.new.call([ stale, stale ])
    payload = Seo::SitemapCache.fetch(site: site).with(xml: xml)
    report = Seo::SitemapReport.new(site: site, entries: entries, payload: payload)
    assert_equal 1, report.missing_count
    assert_equal 1, report.duplicate_count
    assert_equal 2, report.lastmod_mismatches
    assert_equal %w[sitemap_inventory_mismatch sitemap_lastmod_mismatch], report.codes
  end
  test "site term origin and homepage changes advance durable invalidation" do
    item=public_content
    before=site.seo_generation
    category=term
    assert_operator site.seo_generation, :>, before
    change(item, "publish", attributes: { term_ids: [ category.id ] })
    assert_includes sitemap_urls, site.canonical_origin+"/category/news"
    old=site.seo_generation
    category.update!(name: "Renamed category", slug: "renamed-category")
    assert_operator site.seo_generation, :>, old
    assert_includes sitemap_urls, site.canonical_origin+"/category/renamed-category"
    refute_includes sitemap_urls, site.canonical_origin+"/category/news"
    site.update!(canonical_origin: "https://new.example.invalid")
    assert sitemap_urls.all? { |url| url.start_with?("https://new.example.invalid/") }
  end
  test "optional public organization identity uses the stable export extension without operational secrets" do
    site.update!(organization_name: "Original studio")
    public_content
    payload=Portability::Export.call(actor: @owner)
    assert_equal({ "seo"=>{ "organization_name"=>"Original studio" }, "privacy"=>{ "privacy_first_anonymous"=>true } }, payload["extensions"])
    assert Portability::Validate.call(JSON.generate(payload))
    refute_includes JSON.generate(payload), "RAILPRESS_HTTPS_ORIGIN"
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-organization-manifest.json"), JSON.pretty_generate(payload)+"\n")
  end
end
