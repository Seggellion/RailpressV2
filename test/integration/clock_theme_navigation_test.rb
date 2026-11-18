require "test_helper"
require_relative "../support/navigation_test_support"
require_relative "../support/security_clock_test_support"

class ClockThemeNavigationTest < ActionDispatch::IntegrationTest
  include NavigationTestSupport
  include SecurityClockTestSupport

  test "theme preview expires durably and cannot authorize later activation" do
    package = stage
    overlay = package.theme_overlays.first
    session_token = UserSession.issue!(@owner)
    credential = Themes::Manager.preview!(actor: @owner, installation: package, overlay: overlay, authentication_token: session_token)
    record = ThemePreview.find_by!(token_digest: Digest::SHA256.hexdigest(credential["token"]))
    assert Themes::Selection.preview(@owner, session_token, credential)
    travel_to(record.expires_at + 1) { assert_nil Themes::Selection.preview(@owner, session_token, credential) }
    assert_nil Themes::Selection.preview(@owner, session_token, credential)
    assert_raises(Themes::Manager::Protected) { Themes::Manager.activate!(actor: @owner, installation: package, overlay: overlay, version: ThemeState.first.lock_version) }
    assert_nil ThemeState.first.active_installation_id
  end

  test "server navigation preview ignores forged cookie deadlines and revocation survives replay" do
    activate(navigation_package)
    menu = menu_create; add_link(menu, "Draft menu")
    mutate(menu, "assign", { "locations" => [ "dusk:primary" ] })
    session_token = UserSession.issue!(@owner)
    credential = Navigation::Preview.issue(actor: @owner, menu: menu, authentication_token: session_token)
    assert Navigation::Preview.resolve(actor: @owner, authentication_token: session_token, credential: credential)
    assert_nil Navigation::Preview.resolve(actor: @author, authentication_token: session_token, credential: credential)
    record = NavigationPreview.last
    forged = credential.merge("expires_at" => 100.years.from_now.to_i, "actor_id" => @author.id)
    travel_to(record.expires_at + 1) { assert_nil Navigation::Preview.resolve(actor: @owner, authentication_token: session_token, credential: forged) }
    assert_nil Navigation::Preview.resolve(actor: @owner, authentication_token: session_token, credential: forged)
    fresh = Navigation::Preview.issue(actor: @owner, menu: menu, authentication_token: session_token)
    Navigation::Preview.revoke(actor: @owner, authentication_token: session_token, credential: fresh)
    travel(-5.seconds) { assert_nil Navigation::Preview.resolve(actor: @owner, authentication_token: session_token, credential: fresh) }
  end

  test "published page media menu export canonical and sitemap agree through rollback" do
    activate(navigation_package)
    asset = upload_media
    page = change(draft("Page", slug: "durable-guide", blocks: [ { "type" => "image", "media_id" => asset.id } ]), "publish")
    post = change(draft(slug: "durable-post"), "publish")
    hidden = draft(slug: "private-clock-canary", title: "PRIVATE CLOCK CANARY")
    menu = menu_create
    mutate(menu, "add", { "item" => { "kind" => "Page", "content_id" => page.id, "label" => "Durable guide" } })
    assign_publish(menu)
    base = Time.current
    cache = ActiveSupport::Cache::MemoryStore.new
    initial = Seo::SitemapCache.fetch(site: site, cache: cache)
    matrix = []
    [ -1, -2, -3, -5, 5 ].each do |offset|
      travel_to(base + offset, with_usec: true) do
        get "/durable-guide"; assert_response :ok
        assert_select 'link[rel="canonical"][href="https://publishing.example.invalid/durable-guide"]'
        assert nav_slots.primary.any? { |link| link.url == "/durable-guide" }
        get "/blog/durable-post"; assert_response :ok
        get "/blog/#{hidden.slug}"; assert_response :not_found
        get public_media_file_path(content_id: page.id, public_id: asset.public_id, variant: "display"); assert_response :ok
        assert_operator response.body.bytesize, :>, 0
        export = Portability::Export.call(actor: @owner)
        assert_equal 2, export["content"].length
        assert_equal 1, export["media"].length
        refute export["content"].any? { |item| item["ref"] == "post:#{hidden.id}" }
        assert_equal initial.etag, Seo::SitemapCache.fetch(site: site, cache: cache).etag
        matrix << { offset: offset, page: 200, post: 200, draft: 404, public_media: 200, public_export_content: 2, media: 1, unchanged_etag: true }
      end
    end
    change(page, "unpublish")
    refute nav_slots.primary.any? { |link| link.url == "/durable-guide" }
    refute_includes Seo::SitemapCache.fetch(site: site, cache: cache).xml, "/durable-guide"
    clock_evidence("publication-equivalence-matrix", { matrix: matrix, withdrawal_honored: true })
  end
end
