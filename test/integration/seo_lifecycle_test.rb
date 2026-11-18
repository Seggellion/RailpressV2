require "test_helper"
require_relative "../support/security_clock_test_support"
require_relative "../support/public_request_observation"
require_relative "../support/seo_test_support"
class SeoLifecycleTest < ActionDispatch::IntegrationTest
  include SecurityClockTestSupport
  include PublicRequestObservation
  include SeoTestSupport
  def seo_evidence_prefix = ENV.fetch("RAILPRESS_TEST_ENGINE")
  test "full state lifecycle has equivalent HTTP canonical robots schema and sitemap decisions" do
    item=draft(slug: "lifecycle")
    matrix=[]
    observe=->(state, path, visible) do
      observed_public_get path
      row=observed_head
      row["state"]=state
      row["path"]=path
      row["sitemap"]=sitemap_urls.include?(site.canonical_origin+path)
      matrix<<row
      assert_equal visible ? 200 : 404, row["status"], state
      assert_equal visible ? [ site.canonical_origin+path ] : [], row["canonical"], state
      assert_equal [ visible ? "index, follow" : "noindex, nofollow" ], row["robots"], state
      assert_equal visible, row["sitemap"], state
      assert_equal visible, row["schema"].include?("BlogPosting"), state
    end
    observe.call("draft", "/blog/lifecycle", false)
    change(item, "submit")
    observe.call("review", "/blog/lifecycle", false)
    change(item, "schedule", attributes: { schedule_local: 2.hours.from_now.in_time_zone(site.timezone).strftime("%Y-%m-%dT%H:%M") })
    observe.call("scheduled", "/blog/lifecycle", false)
    item.update_columns(scheduled_at: 1.minute.ago)
    with_qualified_utc(Time.current) { assert PublishContentJob.perform_now(item.id, item.lock_version) }
    item.reload
    observe.call("scheduled_publish", "/blog/lifecycle", true)
    first_modified=item.public_updated_at
    change(item, attributes: { title: "PRIVATE WORKING TITLE", meta_title: "PRIVATE SEARCH", body: "<p>UNAPPROVED BODY</p>" })
    observe.call("live_with_private_edits", "/blog/lifecycle", true)
    refute_match(/PRIVATE SEARCH|PRIVATE WORKING TITLE|UNAPPROVED BODY/, response.body)
    assert_equal first_modified, item.reload.public_updated_at
    change(item, "unpublish")
    observe.call("unpublished", "/blog/lifecycle", false)
    change(item, attributes: { slug: "renamed" })
    change(item, "publish")
    get "/blog/lifecycle"
    assert_response :moved_permanently
    assert_equal "/blog/renamed", response.headers["Location"]
    matrix<<observed_head.merge("state"=>"rename_redirect", "location"=>response.headers["Location"], "sitemap"=>sitemap_urls.include?(site.canonical_origin+"/blog/lifecycle"))
    observe.call("renamed_published", "/blog/renamed", true)
    change(item, "trash")
    observe.call("deleted_to_trash", "/blog/renamed", false)
    get "/blog/lifecycle"
    assert_response :not_found
    change(item, "restore")
    observe.call("restored_draft", "/blog/renamed", false)
    path=Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{seo_evidence_prefix}-equivalence.json")
    File.write(path, JSON.pretty_generate(matrix)+"\n")
  end
  test "page homepage and organization graph use only genuine configured metadata" do
    page=draft("Page", slug: "about")
    change(page, "publish")
    get "/about"
    assert_response :success
    types=observed_head["schema"]
    assert_includes types, "WebPage"
    refute_includes types, "Organization"
    refute_includes types, "BlogPosting"
    site.update!(organization_name: "Original studio")
    get "/about"
    assert_includes observed_head["schema"], "Organization"
    change(page, "unpublish")
    change(page, "publish", attributes: { home_page: true })
    get "/"
    assert_equal [ site.canonical_origin+"/" ], observed_head["canonical"]
    assert_equal 1, sitemap_urls.count(site.canonical_origin+"/")
    refute_includes sitemap_urls, site.canonical_origin+"/about"
    get "/about"
    assert_equal "/", response.headers["Location"]
  end
  test "private published and previews never acquire public metadata or inventory" do
    item=public_content(visibility: "private")
    get "/blog/#{item.slug}"
    assert_response :not_found
    refute_includes sitemap_urls, site.canonical_origin+"/blog/#{item.slug}"
    sign_in(self, @author)
    token=csrf_token_for(self, edit_admin_content_path(item))
    post preview_admin_content_path(item), params: { authenticity_token: token, robots: "index", canonical: "https://evil.invalid" }
    get response.location
    assert_response :success
    assert_equal [ "noindex, nofollow" ], observed_head["robots"]
    assert_empty observed_head["canonical"]
    assert_empty observed_head["schema"]
    assert_equal "no-store", response.headers["Cache-Control"]
  end
  test "global visibility and staging switch win over metadata and cached sitemap" do
    item=public_content
    assert_includes sitemap_urls, site.canonical_origin+"/blog/#{item.slug}"
    get "/robots.txt"
    refute_includes response.body, "Disallow: /search"
    site.update!(indexing_enabled: false)
    get "/blog/#{item.slug}?robots=index"
    assert_equal [ "noindex, nofollow" ], observed_head["robots"]
    assert_empty observed_head["schema"]
    assert_empty sitemap_urls
    get "/robots.txt"
    assert_includes response.body, "Disallow: /"
    site.update!(indexing_enabled: true)
    previous=ENV["RAILPRESS_SEO_INDEXING"]
    ENV["RAILPRESS_SEO_INDEXING"]="disabled"
    get "/blog/#{item.slug}"
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_empty sitemap_urls
  ensure
    ENV["RAILPRESS_SEO_INDEXING"]=previous
  end
  test "archive pagination taxonomy search and unknown route policies are explicit" do
    category=term
    13.times { |i| public_content(slug: "result-#{i}", term_ids: [ category.id ], title: "Public result #{i}") }
    %w[/blog /category/news /blog?page=2].each do |path|
      observed_public_get path
      if response.status != 200
        observation = { request_trace: @qualification_request_trace, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), scope: self.class.name, now: Time.current.iso8601(6), monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC),
          path: request.fullpath, status: response.status, rows: Post.order(:id).pluck(:id, :slug, :status, :published_visibility, :published_at), visible_ids: Post.publicly_visible.pluck(:id) }
        File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{seo_evidence_prefix}-seo-page-status-#{SecureRandom.hex(3)}.json"), JSON.pretty_generate(observation)+"\n")
      end
      assert_response :success
      assert_equal [ "index, follow" ], observed_head["robots"]
      assert_equal [ site.canonical_origin+path ], observed_head["canonical"]
    end
    get "/blog?page=1"
    assert_equal "/blog", response.headers["Location"]
    %w[/blog?page=3 /blog?page=1001 /blog?page=bad /unknown/nested].each do |path|
      observed_public_get path
      assert_response :not_found
      assert_empty observed_head["canonical"]
    end
    observed_public_get "/search", params: { q: "Public result" }
    assert_response :success
    if Nokogiri::HTML(response.body).css("article").length != 12
      observation = { request_trace: @qualification_request_trace, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), scope: self.class.name, now: Time.current.iso8601(6), monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        path: request.fullpath, articles: Nokogiri::HTML(response.body).css("article a").map { |node| node["href"] },
        rows: Post.order(:id).pluck(:id, :slug, :status, :published_visibility, :published_at), visible_ids: Post.publicly_visible.pluck(:id) }
      File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{seo_evidence_prefix}-seo-pagination-#{SecureRandom.hex(3)}.json"), JSON.pretty_generate(observation)+"\n")
    end
    assert_select "article", count: 12
    assert_equal [ "noindex, nofollow" ], observed_head["robots"]
    assert_empty observed_head["schema"]
    observed_public_get "/search", params: { q: "Public result", page: 2 }
    assert_select "article", count: 1
    observed_public_get "/search", params: { q: "%" }
    assert_select "article", count: 0
    assert sitemap_urls.none? { |url| url.include?("search") || url.include?("?page=") || url.include?("admin") }
    get "/blog?tracking=attacker"
    assert_equal [ "noindex, nofollow" ], observed_head["robots"]
    assert_equal [ site.canonical_origin+"/blog" ], observed_head["canonical"]
  end
  test "search cannot match private working titles or unpublished text" do
    item=public_content(title: "APPROVED TITLE")
    change(item, attributes: { title: "PRIVATE QUERY", excerpt: "PRIVATE QUERY" })
    draft(slug: "hidden-query", title: "PRIVATE QUERY")
    observed_public_get "/search", params: { q: "PRIVATE QUERY" }
    assert_select "article", count: 0
    observed_public_get "/search", params: { q: "APPROVED TITLE" }
    assert_select "article", count: 1
    refute_includes response.body, "PRIVATE QUERY"
  end
  test "host forwarding and unknown metadata inputs cannot control canonical or redirects" do
    item=public_content
    attack={ "Host"=>"attacker.invalid", "X-Forwarded-Host"=>"evil.invalid", "Forwarded"=>"host=evil.invalid;proto=http" }
    get "/blog/#{item.slug}", headers: attack, params: { canonical: "https://evil.invalid", robots: "index" }
    assert_response :success
    assert_equal [ site.canonical_origin+"/blog/#{item.slug}" ], observed_head["canonical"]
    refute_includes response.body, "evil.invalid"
    get "/blog/#{item.slug.upcase}", headers: attack
    assert_response :moved_permanently
    assert_equal "/blog/#{item.slug}", response.headers["Location"]
    get "/blog/#{item.slug}", params: { page: 2 }
    assert_equal [ "noindex, nofollow" ], observed_head["robots"]
  end
  test "sitemap validators invalidate immediately and ignore unsafe time-only revalidation" do
    item=public_content
    get "/sitemap.xml"
    assert_response :success
    etag=response.headers["ETag"];modified=response.headers["Last-Modified"]
    assert etag
    get "/sitemap.xml", headers: { "If-None-Match"=>etag }
    assert_response :not_modified
    change(item, "unpublish")
    get "/sitemap.xml", headers: { "If-None-Match"=>etag, "If-Modified-Since"=>modified }
    assert_response :success
    refute_includes response.body, "/blog/#{item.slug}"
    get "/sitemap.xml", headers: { "If-Modified-Since"=>modified }
    assert_response :success
  end
  test "cache failures cannot block rendering publishing or expose stale inventory" do
    item=public_content
    broken=Object.new
    def broken.read(*) = raise(IOError, "synthetic cache failure")
    def broken.delete_matched(*) = raise(IOError, "synthetic cache failure")
    with_method(Rails, :cache, -> { broken }) do
      get "/blog/#{item.slug}"
      assert_response :success
      change(item, "unpublish")
      get "/sitemap.xml"
      assert_response :success
      refute_includes response.body, "/blog/#{item.slug}"
    end
  end
  test "escaped metadata and ignored view slots cannot introduce alternate SEO head" do
    item=public_content(meta_title: "</title><script>x()</script>", meta_description: '"><meta name="robots" content="index">')
    get "/blog/#{item.slug}"
    assert_select 'link[rel="canonical"]', count: 1
    assert_select 'meta[name="robots"]', count: 1
    assert_select 'script:not([type="application/ld+json"])', count: 0
    graph=Nokogiri::HTML(response.body).at_css('script[type="application/ld+json"]').text
    assert JSON.parse(graph)
    policy=Seo::Policy.new(site: site, family: :post, path: "/blog/#{item.slug}", content: item)
    assert_raises(FrozenError) { policy.canonical.replace("https://evil.invalid") }
    assert_raises(FrozenError) { policy.site.canonical_origin.replace("https://evil.invalid") }
    assert_raises(FrozenError) { policy.site.title.replace("Unapproved identity") }
    assert_raises(FrozenError) { policy.data["title"] = "Unapproved title" }
    html=ApplicationController.render(inline: '<% content_for :head do %><meta name="robots" content="index"><% end %><p>Fixture body</p>', layout: "public_content", assigns: { site: site, seo: policy })
    document=Nokogiri::HTML(html)
    assert_equal 1, document.css('meta[name="robots"]').length
    assert_equal 1, document.css('link[rel="canonical"]').length
    assert_raises(ArgumentError) { Seo::Policy.new(site: site, family: :post, overrides: { robots: "index" }) }
  end
  test "a forged proxy-derived Rack scheme cannot authorize insecure account access" do
    https!(false)
    controller=ApplicationController.new
    controller.set_request!(ActionDispatch::Request.new({ "rack.url_scheme"=>"https", "HTTPS"=>"off", "HTTP_X_FORWARDED_PROTO"=>"https", "REMOTE_ADDR"=>"127.0.0.1" }))
    refute controller.send(:secure_transport?)
    get "/login", headers: { "X-Forwarded-Proto"=>"https" }
    assert_response :upgrade_required
    assert_equal 0, UserSession.count
    https!
    get "/login"
    assert_response :success
  end
  test "slow cache operations are bounded and publication never invokes a remote cache" do
    item=public_content
    calls=[]
    slow=Object.new
    slow.define_singleton_method(:read) { |*| calls<<:read; sleep 2 }
    slow.define_singleton_method(:write) { |*| calls<<:write; sleep 2 }
    with_method(Rails, :cache, -> { slow }) do
      change(item, "unpublish")
      assert_empty calls
      started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      get "/sitemap.xml"
      assert_response :success
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC)-started, :<, 1.5
      refute_includes response.body, "/blog/#{item.slug}"
    end
  end
end
