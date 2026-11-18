require "stringio"
require "test_helper"
require_relative "../support/navigation_test_support"
class NavigationLifecycleTest < ActionDispatch::IntegrationTest
  include NavigationTestSupport
  test "Dusk assignments draft publish undo deletion and location independence preserve SEO" do
    activate(navigation_package)
    menu = menu_create("A name unrelated to primary"); add_link(menu, "FIRST LIVE")
    mutate(menu, "assign", { "locations" => %w[dusk:primary dusk:footer] })
    observed_public_get "/"; refute_includes response.body, "FIRST LIVE"
    mutate(menu, "publish")
    observed_public_get "/"; assert_select 'nav[aria-label="Primary"] a', text: "FIRST LIVE"; assert_select 'nav[aria-label="Footer"] a', text: "FIRST LIVE"
    assert_select 'link[rel="canonical"]', count: 1
    assert_equal "no-cache", response.headers["Cache-Control"]
    add_link(menu, "DRAFT CANARY")
    observed_public_get "/"; refute_includes response.body, "DRAFT CANARY"
    mutate(menu, "publish")
    observed_public_get "/"; assert_includes response.body, "DRAFT CANARY"
    mutate(menu, "undo", { "revision_id" => menu.menu_revisions.order(:number).last.id })
    observed_public_get "/"; refute_includes response.body, "DRAFT CANARY"
    mutate(menu, "delete")
    observed_public_get "/"; refute_includes response.body, "FIRST LIVE"
    mutate(menu, "undo", { "revision_id" => menu.menu_revisions.order(:number).last.id })
    observed_public_get "/"; assert_includes response.body, "FIRST LIVE"
    evidence("navigation-seo-head", { status: response.status, canonical: Nokogiri::HTML(response.body).at_css('link[rel="canonical"]')["href"], robots: response.headers["X-Robots-Tag"], menu_version: menu.reload.lock_version, generation: site.reload.seo_generation })
  end
  test "typed references follow rename home identity taxonomy and withdrawal without exposing working content" do
    activate(navigation_package)
    page = change(draft("Page", slug: "service", title: "PUBLIC PAGE"), "publish")
    post = public_content(slug: "story")
    topic = term("category", "Design"); change(post, attributes: { term_ids: [ topic.id ] }); change(post, "publish")
    hidden = draft("Page", slug: "private", title: "PRIVATE CANARY", visibility: "private")
    menu = menu_create
    [ [ page, "Page" ], [ post, "Post" ] ].each { |target, kind| mutate(menu, "add", { "item" => { "kind" => kind, "label" => kind, "content_id" => target.id } }) }
    mutate(menu, "add", { "item" => { "kind" => "Term", "label" => "Topic", "term_id" => topic.id } })
    assert_raises(Navigation::Mutation::Invalid) { mutate(menu, "add", { "item" => { "kind" => "Page", "label" => "PRIVATE CANARY", "content_id" => hidden.id } }) }
    assign_publish(menu)
    observed_public_get "/"; assert_select 'nav[aria-label="Primary"] a[href="/service"]'; assert_select 'nav[aria-label="Primary"] a[href="/blog/story"]'; assert_select 'nav[aria-label="Primary"] a[href="/category/design"]'
    change(page, attributes: { title: "WORKING CANARY" })
    observed_public_get "/"; refute_includes response.body, "WORKING CANARY"
    change(page, "unpublish"); change(page, attributes: { slug: "renamed" }); change(page, "publish")
    observed_public_get "/"; assert_select 'nav[aria-label="Primary"] a[href="/renamed"]'; assert_select 'nav[aria-label="Primary"] a[href="/service"]', count: 0
    site.update!(homepage_content_id: page.id)
    observed_public_get "/"; assert_select 'nav[aria-label="Primary"] a[href="/"]', text: "Page"
    change(post, "unpublish")
    observed_public_get "/"; assert_select 'nav[aria-label="Primary"] a[href="/blog/story"],nav[aria-label="Primary"] a[href="/category/design"]', count: 0
    change(page, "trash")
    observed_public_get "/"; refute_includes response.body, "PRIVATE CANARY"; assert_select 'nav[aria-label="Primary"] a', text: "Page", count: 0
  end
  test "preview is session bound noindex no store and revocation resistant" do
    activate(navigation_package)
    menu = menu_create; add_link(menu, "PRIVATE NAV PREVIEW"); mutate(menu, "assign", { "locations" => [ "dusk:primary" ] })
    sign_in
    csrf = csrf_token_for(self, edit_admin_menu_path(menu))
    post preview_admin_menu_path(menu), params: { authenticity_token: csrf }
    observed_public_get "/"; assert_includes response.body, "PRIVATE NAV PREVIEW"; assert_includes response.headers["Cache-Control"], "no-store"
    assert_select 'link[rel="canonical"],script[type="application/ld+json"]', count: 0
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    other = ActionDispatch::Integration::Session.new(Rails.application); other.https!
    other.get "/?menu_id=#{menu.id}&preview=1"; refute_includes other.response.body, "PRIVATE NAV PREVIEW"
    sign_in(other)
    other.get "/"; refute_includes other.response.body, "PRIVATE NAV PREVIEW"
    add_link(menu, "Changed")
    observed_public_get "/"; refute_includes response.body, "PRIVATE NAV PREVIEW"
  end
  test "all direct controller actions authorize and route ownership has no dead menu scaffolds" do
    menu = menu_create
    sign_in(self, @editor)
    csrf = csrf_token_for(self, "/admin")
    observed_public_get "/admin/menus"; assert_response :forbidden
    get edit_admin_menu_path(menu); assert_response :forbidden
    post admin_menus_path, params: { name: "No", state_version: nav_version, authenticity_token: csrf }; assert_response :forbidden
    %w[rename add update remove move reorder reparent assign publish undo].each do |operation|
      patch admin_menu_path(menu), params: { operation: operation, version: menu.lock_version, state_version: nav_version, authenticity_token: csrf }
      assert_response :forbidden
    end
    post preview_admin_menu_path(menu), params: { authenticity_token: csrf }; assert_response :forbidden
    delete admin_menu_path(menu), params: { version: menu.lock_version, state_version: nav_version, authenticity_token: csrf }; assert_response :forbidden
    post admin_menus_stop_preview_path, params: { authenticity_token: csrf }; assert_response :forbidden
  end
  test "long published source titles create editable bounded labels without reading working titles" do
    title = "A published guide — " + "日本語 " * 40
    page = change(draft("Page", title: title, slug: "long-menu-source"), "publish")
    change(page, attributes: { title: "PRIVATE WORKING TITLE" })
    menu = menu_create
    sign_in
    csrf = csrf_token_for(self, edit_admin_menu_path(menu))
    patch admin_menu_path(menu), params: { operation: "add", target: "Page:#{page.id}", version: menu.lock_version, state_version: nav_version, authenticity_token: csrf }
    assert_response :see_other
    item = menu.menu_items.first
    assert_equal page.id, item.content_id
    assert_equal "Page", item.kind
    assert_equal 120, item.label.length
    assert item.label.valid_encoding?
    assert item.label.start_with?("A published guide")
    refute_includes item.label, "PRIVATE WORKING TITLE"
  end
  test "rejected link credentials never enter controller logs or public state" do
    sign_in
    menu = menu_create
    csrf = csrf_token_for(self, edit_admin_menu_path(menu))
    buffer = StringIO.new
    logger = ActiveSupport::Logger.new(buffer); logger.level = Logger::DEBUG
    original = ActionController::Base.logger
    ActionController::Base.logger = logger
    secret = "synthetic-rejected-menu-secret"
    patch admin_menu_path(menu), params: { operation: "add", item: { kind: "Custom", label: "Unsafe link", url: "https://fixture-user:#{secret}@example.invalid/" }, version: menu.lock_version, state_version: nav_version, authenticity_token: csrf }
    assert_response :unprocessable_entity
    refute MenuItem.exists?(label: "Unsafe link")
    refute_includes response.body, secret
    refute_includes buffer.string, secret
    assert_includes buffer.string, "FILTERED"
  ensure
    ActionController::Base.logger = original if original
  end
  test "server editor feedback escapes user labels and retains stale comparison" do
    sign_in
    csrf = csrf_token_for(self, "/admin/menus")
    post admin_menus_path, params: { name: "Main <script>alert(1)</script>", state_version: nav_version, authenticity_token: csrf }
    assert_response :see_other
    menu = Menu.last; get edit_admin_menu_path(menu); assert_response :ok
    assert_select "h1", text: menu.name; assert_select "script:not([src])", count: 0
    version = menu.lock_version; state = nav_version; add_link(menu, "New winner")
    patch admin_menu_path(menu), params: { operation: "reorder", tree: "[]", version: version, state_version: state, authenticity_token: csrf }
    assert_response :conflict
    assert_includes response.body, "Compare your submitted tree"
    assert_includes response.body, "New winner"
    patch admin_menu_path(menu), params: { operation: "add", item: { kind: "Custom", label: "Bad", url: "javascript:alert(1)" }, version: menu.reload.lock_version, state_version: nav_version, authenticity_token: csrf }
    assert_response :unprocessable_entity
    refute MenuItem.exists?(label: "Bad")
  end
end
