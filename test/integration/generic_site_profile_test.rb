require "test_helper"
require_relative "../support/installation_test_support"
require_relative "../support/generic_site_fixture"

class GenericSiteProfileTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport
  def site_attributes
    super.merge(title: "Railpress", canonical_origin: "https://railpress.org", timezone: "UTC")
  end
  def install_fields(step)
    return { "brand_label"=>"Railpress", "about"=>"0", "contact"=>"0" } if step == "appearance"
    super
  end
  setup do
    @previous_profile_confirmation = ENV["RAILPRESS_GENERIC_FIXTURE"]
    ENV["RAILPRESS_GENERIC_FIXTURE"] = "generic-synthetic-only"
  end
  teardown { ENV["RAILPRESS_GENERIC_FIXTURE"] = @previous_profile_confirmation }
  def installed_profile
    csrf = review_install
    post "/setup/complete", params: finish_params(csrf)
    assert_response :see_other
    @owner = Site.first.owner
    # Normal generic install contains one starter draft, not official articles.
    assert_equal [ "your-first-story" ], Post.pluck(:slug)
    GenericSiteFixture.load!(actor: @owner)
  end
  test "fresh ordinary installation keeps all twenty complete editorial Posts private through every public consumer" do
    fixture = installed_profile
    assert_equal 20, Post.count
    assert_equal 20, Post.where(status: "draft", visibility: "private").count
    assert_equal 13, Page.publicly_visible.count
    assert_equal "dusk", ThemeState.first.active_installation.theme_key
    assert_equal "1.4.0", ThemeState.first.active_installation.version
    assert_equal 4, MenuLocation.where.not(published_menu_id: nil).count
    Site.first.update!(indexing_enabled: true)
    inventory = Seo::UrlInventory.call(site: Site.first)
    package = ThemeState.first.active_installation
    bundle = Themes::Storage.load(package)
    offline = []
    fixture[:posts].each_value do |item|
      assert_nil item.published_snapshot
      get "/blog/#{item.slug}"
      assert_response :not_found
      refute_includes response.body, item.title
      refute inventory.to_s.include?("/blog/#{item.slug}")
      # Authorized in-memory typography qualification only. Public controller
      # never receives this private working presenter; protected preview stays core.
      assert Identity::Capabilities.can_edit_content?(@owner, author_id: item.author_id)
      context = Themes::Context.build(site: Site.first, family: "post", presenter: ContentPresenter.new(item, snapshot: item.snapshot), presenters: [], query: nil, title: item.title,
        page: 1, more: false, path: "/blog/#{item.slug}", options: fixture[:overlay].options)
      rendered = Railpress::ThemeRenderer.render(bundle, context)
      assert_equal item.title, Nokogiri::HTML5.fragment(rendered.body).at_css("h1").text
      assert_includes rendered.body, "Related reading"
      offline << { slug: item.slug, rendered_sha256: Digest::SHA256.hexdigest(rendered.body), bytes: rendered.body.bytesize }
    end
    evidence = Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE", "qualification"))
    FileUtils.mkdir_p(evidence)
    File.open(evidence.join("#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-private-dusk-#{SecureRandom.hex(4)}.json"), "wx") do |file|
      file.write(JSON.pretty_generate({ mode: "authorized test-only working presenter; no public HTTP route", articles: offline }) + "\n")
    end
    fixture[:pages].each_value do |item|
      path = Seo::RouteRegistry.content_path(item, Site.first)
      get path
      assert_response :success
      document = Nokogiri::HTML5(response.body)
      assert_equal 1, document.css("main h1").length
      assert_equal [ "https://railpress.org#{path}" ], document.css('link[rel="canonical"]').map { |node| node["href"] }
      refute_match(/Another change was saved|PRIVATE WORKING/, response.body)
    end
    get "/blog"
    assert_response :success
    get "/search", params: { q: "Synthetic editorial example" }
    assert_response :success
    refute_includes response.body, "Synthetic editorial example 01"
    get "/api/public/v1/news.json"
    assert_response :not_found
    assert_empty OfficialNewsReview.where(content_id: fixture[:posts].values.map(&:id))
    assert_raises(GenericSiteFixture::Invalid) { GenericSiteFixture.load!(actor: @owner) }
  end
  test "ordinary synthetic publication proves archive SEO feed and editing without publishing the real corpus" do
    fixture = installed_profile
    Site.first.update!(indexing_enabled: true)
    controls = GenericSiteFixture.synthetic_posts!(actor: @owner)
    first = controls.first
    controls.first(2).each { |item| OfficialNews::Provider.review!(actor: @owner, content_id: item.id, expected_version: item.lock_version) }
    OfficialNews::Controls.call(actor: @owner, operation: "provider_enable", version: 0)
    get "/api/public/v1/news.json"
    assert_response :success
    payload = OfficialNews::Schema.parse(response.body)
    assert_equal 2, payload["items"].length
    assert payload["items"].all? { |row| row["title"].start_with?("Synthetic") }
    refute_match(/body_file|public_byline|AWAITING OWNER|@example|deadline_binding/, response.body)
    get "/blog/#{first.slug}"
    assert_response :success
    document = Nokogiri::HTML5(response.body)
    graph = document.css('script[type="application/ld+json"]').flat_map { |node| JSON.parse(node.text).fetch("@graph") }
    article = graph.find { |node| node["@type"] == "BlogPosting" }
    assert_equal first.first_published_at.utc.iso8601(6), article.fetch("datePublished")
    assert_equal "https://railpress.org/blog/#{first.slug}", article.fetch("url")
    assert document.at_css("table caption")
    assert_equal 2, document.css('table th[scope="col"]').length
    assert_equal 2, document.css('table th[scope="row"]').length
    assert document.at_css("pre code")
    assert document.at_css("blockquote")
    get "/blog?page=2"
    assert_response :success
    get "/category/qualification-examples"
    assert_response :success
    get "/tag/synthetic-layout-test"
    assert_response :success
    draft = fixture[:posts].values.first
    previous = draft.content_revisions.count
    Editorial::Workflow.update!(actor: @owner, content: draft, expected_version: draft.lock_version, attributes: { "body"=>draft.body + "<p>Private revision qualification.</p>" })
    assert_equal previous + 1, draft.content_revisions.count
    assert_equal "draft", draft.reload.status
    csrf = csrf_token_for(self, "/admin/contents/#{draft.id}/edit")
    post "/admin/contents/#{draft.id}/preview", params: { authenticity_token: csrf }
    assert_response :see_other
    preview_path = response.headers["Location"]
    get preview_path
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["X-Robots-Tag"], "noindex"
    assert_includes response.body, "Private revision qualification."
    assert_equal 20, Post.where(status: "draft", visibility: "private").count
    assert_empty OfficialNewsReview.where(content_id: fixture[:posts].values.map(&:id))
    anonymous = ActionDispatch::Integration::Session.new(Rails.application)
    anonymous.https!
    anonymous.get(preview_path)
    refute_equal 200, anonymous.response.status
  end
  test "editorial fixture rejects unsafe paths unapproved publication and missing explicit target confirmation" do
    value = GenericSiteFixture.corpus
    assert_equal 20, GenericSiteFixture.validate!(value).length
    changed = value.deep_dup
    changed["articles"].first["body_file"] = "../../.local/state/test-targets.json"
    assert_raises(GenericSiteFixture::Invalid) { GenericSiteFixture.validate!(changed) }
    changed = value.deep_dup
    changed["articles"].first["status"] = "published"
    assert_raises(GenericSiteFixture::Invalid) { GenericSiteFixture.validate!(changed) }
    changed = value.deep_dup
    changed["articles"].first["public_byline"] = "Invented approval"
    assert_raises(GenericSiteFixture::Invalid) { GenericSiteFixture.validate!(changed) }
    ENV.delete("RAILPRESS_GENERIC_FIXTURE")
    assert_raises(GenericSiteFixture::Invalid) { GenericSiteFixture.guard! }
    ENV["RAILPRESS_GENERIC_FIXTURE"] = "generic-synthetic-only"
    previous_host = ENV["RAILPRESS_DB_HOST"]
    begin
      ENV["RAILPRESS_DB_HOST"] = "unapproved.example.invalid"
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { GenericSiteFixture.guard! }
    ensure
      previous_host ? ENV["RAILPRESS_DB_HOST"] = previous_host : ENV.delete("RAILPRESS_DB_HOST")
    end
  end
end
