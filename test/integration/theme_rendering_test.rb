require "test_helper"
require_relative "../support/theme_test_support"
class ThemeRenderingTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  test "public dispatcher renders only immutable live presenters and core owns SEO and private routes" do
    package = stage; activate(package)
    item = public_content(slug: "theme-post")
    change(item, attributes: { title: "PRIVATE THEME CANARY", body: "PRIVATE BODY CANARY" })
    secret = draft(slug: "theme-secret")
    matrix = []
    [ "/", "/blog", "/blog/theme-post", "/search?q=Caf", "/search?q=absent", "/missing/nested" ].each do |path|
      get path
      assert_equal path.include?("missing") ? 404 : 200, response.status
      assert_includes response.body, 'data-theme="harbor"'
      assert_select "head title", count: 1
      refute_match(/PRIVATE THEME CANARY|PRIVATE BODY CANARY/, response.body)
      matrix << observed_head.merge("path" => path)
    end
    get "/blog/#{secret.slug}"
    assert_response :not_found
    refute_includes response.body, secret.title
    get "/blog/theme-post", headers: { "Host" => "attacker.invalid" }
    assert_select 'link[rel="canonical"][href="https://publishing.example.invalid/blog/theme-post"]', count: 1
    %w[/login /password/recovery /up /setup].each do |path|
      get path
      refute_includes response.body, 'data-theme="harbor"'
    end
    get "/sitemap.xml"; assert_includes response.body, "/blog/theme-post"; refute_includes response.body, "theme-secret"
    sign_in
    get "/admin/themes"; assert_response :ok; refute_includes response.body, 'data-theme="harbor"'
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-theme-head-matrix.json"), JSON.pretty_generate(matrix) + "\n")
  end
  test "owner preview is isolated from simultaneous anonymous requests and stop restores active" do
    dusk = stage("dusk"); activate(dusk)
    harbor = stage
    overlay = Themes::Manager.overlay!(actor: @owner, installation: harbor, attributes: { footer: "OWNER PREVIEW CANARY" })
    sign_in
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/#{harbor.id}/preview", params: { overlay_id: overlay.id, authenticity_token: csrf }
    assert_response :see_other
    anonymous = ActionDispatch::Integration::Session.new(Rails.application); anonymous.https!
    clients = [ self, anonymous ]
    results = parallel_results(2) do |index|
      clients[index].get("/")
      { body: clients[index].response.body, cache: clients[index].response.headers["Cache-Control"] }
    end
    assert_includes results[0][:body], "OWNER PREVIEW CANARY"
    assert_includes results[0][:body], 'data-theme="harbor"'
    assert_includes results[0][:cache], "no-store"
    document = Nokogiri::HTML(results[0][:body])
    assert_equal "noindex, nofollow", document.at_css('meta[name="robots"]')["content"]
    assert_empty document.css('link[rel="canonical"],script[type="application/ld+json"]')
    refute_includes results[1][:body], "OWNER PREVIEW CANARY"
    assert_includes results[1][:body], 'data-theme="dusk"'
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/stop-preview", params: { authenticity_token: csrf }
    get "/"; assert_includes response.body, 'data-theme="dusk"'; refute_includes response.body, "OWNER PREVIEW CANARY"
  end
  test "versioned assets retain previous digest and unpreviewed candidates sources and traversal are private" do
    dusk = stage("dusk"); harbor = stage
    asset_path = ->(package) { "/theme-assets/#{package.theme_key}/#{package.version}/#{package.digest}/public.css" }
    get asset_path.call(harbor); assert_response :not_found
    activate(dusk)
    get asset_path.call(dusk); assert_response :ok; bytes = response.body
    assert_includes response.headers["Cache-Control"], "immutable"
    activate(harbor)
    get asset_path.call(dusk); assert_response :ok; assert_equal bytes, response.body
    get asset_path.call(harbor); assert_response :ok; assert_equal "text/css", response.media_type
    get asset_path.call(harbor).sub("public.css", "post.html.erb"); assert_response :not_found
    get asset_path.call(harbor).sub("public.css", "..%2fmanifest.json"); assert_response :not_found
    Themes::Manager.revert!(actor: @owner, version: ThemeState.first.lock_version)
    get asset_path.call(harbor); assert_response :ok
  end
  test "runtime error returns emergency core 503 retains active identity and admin remains operable" do
    package = stage(mutate: ->(manifest, directory) do
      Railpress::ThemeFixture.replace(manifest, directory, "templates/home.html.erb", '<% raise "unexpected request fixture" if theme.site.title == "Synthetic Railpress" %><p>Safe smoke</p>')
    end)
    activate(package)
    get "/"
    assert_response :service_unavailable
    assert_includes response.body, "Site temporarily unavailable"
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select 'link[rel="canonical"],script', count: 0
    assert_equal package.id, ThemeState.first.active_installation_id
    sign_in; get "/admin/themes"; assert_response :ok
    assert_includes response.body, package.public_identity
    get "/up"; assert_response :ok
  end
  test "all nonowner mutations and CSRF activation fail with current identity intact" do
    package = stage
    sign_in
    post "/admin/themes/#{package.id}/activate", params: { overlay_id: package.theme_overlays.first.id, version: 0 }
    assert_response :unprocessable_entity
    %w[administrator editor author].each do |role|
      user = role == "editor" ? @editor : (role == "author" ? @author : create_account(role))
      sign_in(self, user)
      csrf = csrf_token_for(self, "/admin")
      %w[preview activate overlay].each do |action|
        post "/admin/themes/#{package.id}/#{action}", params: { authenticity_token: csrf, overlay_id: package.theme_overlays.first.id, version: 0, overlay: { footer: "unauthorized" } }
        assert_response :forbidden
      end
      delete "/admin/themes/#{package.id}", params: { authenticity_token: csrf }; assert_response :forbidden
      post "/admin/themes/revert", params: { authenticity_token: csrf, version: 0 }; assert_response :forbidden
    end
    assert_nil ThemeState.first.active_installation_id
    assert_equal 1, package.theme_overlays.count
  end
  test "core escapes untrusted identity text and refuses body head and arbitrary resolver paths" do
    package = stage; activate(package)
    Site.first.update!(title: "<img src=x onerror=alert(1)>")
    get "/"
    assert_response :ok
    assert_select "header img", count: 0
    context = Railpress::ThemeRenderer.fixture_context("page")
    assert context.frozen?
    assert context.site.frozen?
    assert context.items.frozen?
    assert_raises(FrozenError) { context.items << "leak" }
    assert_raises(FrozenError) { context.content.title << "edit" }
    assert_raises(Railpress::ThemeRenderer::Invalid) { Railpress::ThemeRenderer.guard!('<form action="/admin" method="post"></form>') }
    assert_raises(Railpress::ThemeRenderer::Invalid) { Railpress::ThemeRenderer.guard!('<img src="//attacker.invalid/x">') }
  end
end
