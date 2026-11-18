require "test_helper"
require_relative "../support/public_request_observation"
require_relative "../support/editorial_test_support"

class EditorialVisibilityTest < ActionDispatch::IntegrationTest
  include PublicRequestObservation
  include EditorialTestSupport
  test "ordinary routes archive taxonomy feed and sitemap expose only published public snapshots" do
    Site.first.update!(indexing_enabled: true)
    category = term
    shown = draft(slug: "visible", term_ids: [ category.id ])
    change(shown, "publish")
    hidden = []
    hidden << draft(slug: "draft")
    private_post = draft(slug: "private", visibility: "private")
    change(private_post, "publish")
    hidden << private_post
    future = draft(slug: "future")
    change(future, "schedule", attributes: { schedule_local: 1.day.from_now.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M") })
    hidden << future
    trashed = draft(slug: "trashed")
    change(trashed, "trash")
    hidden << trashed
    hidden.each do |item|
      get "/blog/#{item.slug}"
      assert_response :not_found
    end
    %w[/blog /category/news /feed.xml /sitemap.xml].each do |path|
      observed_public_get path
      assert_response :success
      unless response.body.include?("visible")
        observation = { request_trace: @qualification_request_trace, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), now: Time.current.iso8601(6), monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC),
          path: request.fullpath, status: response.status, rows: Post.order(:id).pluck(:id, :slug, :status, :published_visibility, :published_at), visible_ids: Post.publicly_visible.pluck(:id) }
        File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-visibility-observation-#{SecureRandom.hex(3)}.json"), JSON.pretty_generate(observation)+"\n")
      end
      assert_includes response.body, "visible"
      hidden.each { |item| refute_includes response.body, "/blog/#{item.slug}" }
    end
    get "/blog/visible", headers: { "Host" => "untrusted.example.invalid" }
    assert_response :success
    assert_select 'link[rel="canonical"][href="https://publishing.example.invalid/blog/visible"]'
    assert_select "h2", text: "Welcome"
  end
  test "draft Page is hidden static home is empty until published and blog mode uses posts" do
    get "/"
    assert_response :success
    assert_includes response.body, "nothing published"
    page = draft("Page", slug: "about", home_page: true)
    get "/about"
    assert_response :not_found
    change(page, "publish")
    get "/"
    assert_response :success
    assert_select "h1", text: page.title
    get "/about"
    assert_redirected_to "/"
    Site.first.update!(home_mode: "blog")
    get "/"
    assert_response :success
    assert_select "h1", text: "Blog"
  end
  test "saving edits cannot leak working title body metadata or categories" do
    old_term = term
    new_term = term("category", "Working")
    item = draft(slug: "stable", term_ids: [ old_term.id ], body: "<p>Live body</p>", meta_title: "Live search")
    change(item, "publish")
    change(item, attributes: { title: "SECRET DRAFT", body: "<p>PRIVATE BODY</p>", meta_title: "PRIVATE META", term_ids: [ new_term.id ] })
    %w[/blog/stable /blog /feed.xml /category/news].each do |path|
      observed_public_get path
      assert_response :success
      refute_match(/SECRET DRAFT|PRIVATE BODY|PRIVATE META/, response.body)
    end
    get "/category/working"
    refute_includes response.body, "/blog/stable"
    get "/category/news"
    assert_includes response.body, "/blog/stable"
  end
  test "canonical normalization pagination and reserved core routes are deterministic" do
    content = draft("Page", slug: "café")
    change(content, "publish")
    get "/CAFE"
    assert_redirected_to "/cafe"
    get "/setup"
    assert_response :gone
    13.times do |index|
      item = draft(slug: "article-#{index}")
      change(item, "publish")
    end
    observed_public_get "/blog"
    if Nokogiri::HTML(response.body).css("article").length != 12
      state = { request_trace: @qualification_request_trace, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), now: Time.current.iso8601(6), params: request.query_parameters,
        articles: Nokogiri::HTML(response.body).css("article a").map { |node| node["href"] },
        rows: Post.order(:id).pluck(:id, :slug, :status, :published_visibility, :published_at),
        visible_ids: Post.publicly_visible.pluck(:id) }
      File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-pagination-observation-#{SecureRandom.hex(3)}.json"), JSON.pretty_generate(state)+"\n")
    end
    assert_select "article", count: 12
    assert_select 'a[href="/blog?page=2"]', text: "Next page"
    get "/blog?page=2"
    assert_select "article", count: 1
    get "/blog?page=-1"
    assert_response :not_found
  end
  test "preview is private expiring session-bound and leaves live content unchanged" do
    item = draft
    change(item, "publish")
    change(item, actor: @author, attributes: { body: "<p>Unpublished preview</p>" })
    sign_in(self, @author)
    csrf = csrf_token_for(self, edit_admin_content_path(item))
    post preview_admin_content_path(item), params: { authenticity_token: csrf }
    assert_response :see_other
    location = response.location
    refute_match(/[a-f0-9]{64}/, location)
    get location
    assert_response :success
    assert_includes response.body, "Unpublished preview"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    public_client = ActionDispatch::Integration::Session.new(Rails.application)
    public_client.https!
    public_client.get("/blog/#{item.slug}")
    refute_includes public_client.response.body, "Unpublished preview"
    public_client.get(location)
    assert_equal 303, public_client.response.status
    travel 11.minutes do
      get location
      assert_response :not_found
    end
  end
  test "HTTP actions enforce capabilities authorship CSRF and conflict responses" do
    item = draft
    sign_in(self, @author)
    csrf = csrf_token_for(self, edit_admin_content_path(item))
    patch admin_content_path(item), params: { version: item.lock_version, editorial_action: "publish", authenticity_token: csrf }
    assert_response :forbidden
    patch admin_content_path(item), params: { version: item.lock_version, content: { title: "No CSRF" } }
    assert_response :unprocessable_entity
    patch admin_content_path(item), params: { version: item.lock_version, content: { title: "Author save", author_id: @owner.id, status: "published" }, authenticity_token: csrf }
    assert_response :see_other
    assert_equal @author.id, item.reload.author_id
    assert_equal "draft", item.status
    csrf = csrf_token_for(self, edit_admin_content_path(item))
    patch admin_content_path(item), params: { version: 0, content: { title: "STALE" }, authenticity_token: csrf }
    assert_response :conflict
    assert_includes response.body, "STALE"
    assert_equal "Author save", item.reload.title
    other = draft(actor: @editor, slug: "other")
    get edit_admin_content_path(other)
    assert_response :forbidden
    get admin_contents_path
    refute_includes response.body, edit_admin_content_path(other)
  end
  test "editor form creation revision diff and restore work with genuine CSRF" do
    sign_in(self, @editor)
    csrf = csrf_token_for(self, new_admin_content_path(kind: "Page"))
    post admin_contents_path, params: { kind: "Page", content: { title: "Browser-like roundtrip", body: "<p>Original <em>日本語</em></p>" }, authenticity_token: csrf }
    assert_response :see_other
    item = Page.last
    get response.location
    assert_select 'label[for="content_title"]'
    assert_select 'script[src*="editor"]'
    assert_select "button", text: "Submit for review"
    csrf = csrf_token_for(self, edit_admin_content_path(item))
    patch admin_content_path(item), params: { version: item.lock_version, editorial_action: "publish", authenticity_token: csrf, content: { body: "<p>Changed</p>" } }
    assert_response :see_other
    get revisions_admin_content_path(item, revision: item.content_revisions.first.id)
    assert_response :success
    assert_includes response.body, "Original"
    csrf = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')["content"]
    patch admin_content_path(item), params: { version: item.reload.lock_version, editorial_action: "restore_revision", revision_id: item.content_revisions.first.id, authenticity_token: csrf }
    assert_response :see_other
    assert_equal "draft", item.reload.status
    assert_includes item.body, "Original"
  end

  test "homepage canonical inventory and framework media boundary are core owned" do
    # Canonical ownership is independent of the host wall-clock. Native rollback
    # qualification separately verifies actual SQL cutoffs; retain every assertion.
    freeze_time do
      Site.first.update!(indexing_enabled: true)
      item = draft("Page", slug: "home", home_page: true)
      change(item, "publish")
      get "/"
      assert_select 'link[rel="canonical"][href="https://publishing.example.invalid/"]'
      observed_public_get "/home"
      if response.status != 301
        observation = { request_trace: @qualification_request_trace, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"),
          row: item.reload.attributes.slice("id", "type", "slug", "status", "published_visibility", "published_at", "lock_version"),
          homepage_content_id: Site.first.homepage_content_id, now: Time.current.iso8601(6) }
        File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M08')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-home-alias-observation-#{SecureRandom.hex(4)}.json"), JSON.pretty_generate(observation) + "\n")
      end
      assert_redirected_to "/"
      get "/sitemap.xml"
      assert_includes response.body, "<loc>https://publishing.example.invalid/</loc>"
      refute_includes response.body, "/home</loc>"
      post "/rails/active_storage/direct_uploads", params: { blob: { filename: "untrusted.html" } }
      assert_response :not_found
    end
  end
  test "preinstall public routes redirect without database access" do
    File.unlink(File.join(@private_root, "setup.json"))
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      %w[/ /blog /some-page /sitemap.xml /feed.xml /category/news].each do |path|
        observed_public_get path
        assert_response :see_other
        assert_redirected_to "/setup"
      end
    end
    assert_empty statements
  end

  test "real form origin policy preserves same-origin checks and still rejects null origins" do
    get "/login"
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    csrf = Nokogiri::HTML(response.body).at_css('input[name="authenticity_token"]')["value"]
    post "/login", params: { identifier: @owner.username, password: PASSWORD, authenticity_token: csrf }, headers: { "Origin" => "null" }
    assert_response :unprocessable_entity
    assert_equal 0, UserSession.count
    csrf = csrf_token_for(self, "/login")
    post "/login", params: { identifier: @owner.username, password: PASSWORD, authenticity_token: csrf }, headers: { "Origin" => "https://www.example.com" }
    assert_response :see_other
    assert_equal 1, UserSession.count
  end
end
