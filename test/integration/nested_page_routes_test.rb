require "test_helper"
require_relative "../support/seo_test_support"

class NestedPageRoutesTest < ActionDispatch::IntegrationTest
  include SeoTestSupport

  test "ordinary nested Pages share canonical publication navigation and export policy" do
    page = draft("Page", slug: "docs/getting-started", body: "<h2>A real guide</h2><p>Local documentation.</p>")
    get "/docs/getting-started"
    assert_response :not_found
    change(page, "publish")
    get "/docs/getting-started"
    assert_response :success
    assert_equal [ site.canonical_origin + "/docs/getting-started" ], observed_head["canonical"]
    assert_equal [ "index, follow" ], observed_head["robots"]
    assert_includes sitemap_urls, site.canonical_origin + "/docs/getting-started"
    assert_equal "/docs/getting-started", Navigation::Destinations.resolve({ "kind"=>"Page", "content_id"=>page.id }, site)
    assert Navigation::Destinations.public_path?("/docs/getting-started", site, Time.current)
    manifest = Portability::Export.call(actor: @owner)
    assert_equal "docs/getting-started", Portability::Validate.call(JSON.generate(manifest))["content"].first["slug"]
    get "/DOCS/GETTING-STARTED"
    assert_response :moved_permanently
    assert_equal "/docs/getting-started", response.headers["Location"]
    change(page, "unpublish")
    get "/docs/getting-started"
    assert_response :not_found
    refute Navigation::Destinations.public_path?("/docs/getting-started", site, Time.current)
    refute_includes sitemap_urls, site.canonical_origin + "/docs/getting-started"
  end

  test "nested rename has one hop redirects and protected prefixes cannot be claimed" do
    page = draft("Page", slug: "docs/old-guide")
    change(page, "publish")
    change(page, "unpublish")
    change(page, attributes: { slug: "docs/new-guide" })
    change(page, "publish")
    get "/docs/old-guide"
    assert_response :moved_permanently
    assert_equal "/docs/new-guide", response.headers["Location"]
    assert_raises(ActiveRecord::RecordInvalid) { draft("Page", slug: "docs/old-guide") }
    Railpress::ContentRoutes::RESERVED.each do |prefix|
      assert_raises(ActiveRecord::RecordInvalid) { draft("Page", slug: "#{prefix}/secret") }
      refute Seo::RouteRegistry.redirect_source?("/#{prefix}/secret") unless prefix == "blog"
    end
    %w[docs/../secret docs//secret /docs/secret docs/secret/ a/b/c/d docs/%61dmin docs/secret?x docs/secret#x].each do |slug|
      assert_raises(ActiveRecord::RecordInvalid, slug) { draft("Page", slug: slug) }
    end
    %w[theme-assets/secret theme-media/secret/logo].each do |slug|
      assert_raises(ActiveRecord::RecordInvalid) { draft("Page", slug: slug) }
      refute Seo::RouteRegistry.redirect_source?("/#{slug}")
    end
    private_page = draft("Page", slug: "docs/private", visibility: "private")
    change(private_page, "publish")
    get "/docs/private"
    assert_response :not_found
    change(page, "unpublish")
    get "/docs/old-guide"
    assert_response :not_found
  end

  test "flat keys remain stable and concurrent nested identity creation has one winner" do
    %w[Page Post].each do |kind|
      legacy = draft(kind, slug: "theme-media")
      change(legacy, "publish")
      get Railpress::ContentRoutes.path(kind, "theme-media")
      assert_response :success
    end
    flat = draft("Page", slug: "docs-getting-started")
    assert_equal Railpress::ContentRoutes.key(flat.slug), flat.slug_key
    nested = draft("Page", slug: "docs/getting-started")
    refute_equal flat.slug_key, nested.slug_key
    results = parallel_results(2) do
      begin
        Editorial::Workflow.create!(actor: User.find(@owner.id), kind: "Page", attributes: { "title"=>"Concurrent guide", "slug"=>"docs/concurrent", "visibility"=>"private" })
        "created"
      rescue ActiveRecord::RecordNotUnique
        "conflict"
      end
    end
    assert_equal [ "conflict", "created" ], results.sort
    assert_equal 1, Page.where(slug: "docs/concurrent").count
  end

  test "semantic tables and code survive sanitizing without active attributes" do
    safe = Editorial::RichText.clean('<table onclick="bad()"><caption>Qualified engines</caption><thead><tr><th scope="col">Engine</th></tr></thead><tbody><tr><td style="color:red">PostgreSQL</td></tr></tbody></table><pre><code>bin/railpress doctor</code></pre><script>bad()</script>')
    document = Nokogiri::HTML5.fragment(safe)
    assert_equal "Engine", document.at_css('th[scope="col"]').text
    assert_equal "Qualified engines", document.at_css("caption").text
    assert_equal "bin/railpress doctor", document.at_css("pre code").text
    assert_empty document.css("script, [onclick], [style]")
  end
end
