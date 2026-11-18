require "test_helper"
require_relative "../support/theme_test_support"
class ThemeMediaTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  test "theme presents approved media blocks external editorial links and overlay snapshots" do
    package = stage
    asset = upload_media(actor: @owner)
    overlay = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { logo_id: asset.id, favicon_id: asset.id, footer: "Snapshot footer" })
    activate(package, overlay)
    item = draft(actor: @owner, slug: "theme-media", body: '<p><a href="https://example.invalid/approved">Approved outside link</a></p>',
      featured_media_id: asset.id, blocks: [ { type: "image", media_id: asset.id }, { type: "call_to_action", heading: "Read", text: "Original", label: "Outside", url: "https://example.invalid/action" } ])
    change(item, "publish")
    get "/blog/theme-media"
    assert_response :ok
    assert_select 'a[href="https://example.invalid/approved"]', count: 1
    assert_select 'a[href="https://example.invalid/action"]', count: 1
    assert_select "figure img", count: 2
    assert_select 'link[rel="icon"][href=?]', "/theme-media/#{overlay.id}/favicon", count: 1
    assert_select 'link[rel="icon"][href^="/brand/"]', count: 0
    assert_select 'header img[alt="A synthetic blue studio"]', count: 1
    sign_in
    get "/admin/themes"
    assert_select 'link[rel="icon"][href=?]', CoreBrandHelper::PNG_ICON, count: 1
    assert_select 'link[rel="icon"][href^="/theme-media/"]', count: 0
    get "/theme-media/#{overlay.id}/logo"
    assert_response :ok
    assert_equal "image/png", response.media_type
    assert_includes response.headers["Cache-Control"], "no-store"
    MediaLibrary::Manage.update!(actor: @owner, asset: asset, attributes: { alt_text: "Changed later" }, version: asset.reload.lock_version)
    get "/"
    assert_select 'header img[alt="A synthetic blue studio"]', count: 1
    other = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { logo_id: asset.id })
    get "/theme-media/#{other.id}/logo"; assert_response :not_found
    get "/theme-media/#{overlay.id}/unlisted"; assert_response :not_found
    assert_raises(MediaLibrary::Manage::InUse) { MediaLibrary::Manage.purge!(actor: @owner, asset: asset) }
  end
  test "activation requires exact owner preview receipt and expired preview cannot authorize switch" do
    package = stage
    overlay = package.theme_overlays.first
    assert_raises(Themes::Manager::Protected) { Themes::Manager.activate!(actor: @owner, installation: package, overlay: overlay, version: 0) }
    prepare_preview(package)
    ThemePreview.update_all(expires_at: 1.minute.ago)
    assert_raises(Themes::Manager::Protected) { Themes::Manager.activate!(actor: @owner, installation: package, overlay: overlay, version: 0) }
    activate(package)
    assert_equal package.id, ThemeState.first.active_installation_id
  end
  test "removed historical catalog retains immutable digest assets after multiple switches" do
    first = stage; dusk = stage("dusk"); newer = stage("harbor", version: "1.1.0")
    activate(first); activate(dusk); activate(newer)
    Themes::Manager.remove!(actor: @owner, installation: first)
    assert_equal "removed", first.reload.status
    get "/theme-assets/#{first.theme_key}/#{first.version}/#{first.digest}/public.css"
    assert_response :ok
    assert_equal first.manifest["assets"]["public"]["sha256"], Digest::SHA256.hexdigest(response.body)
    assert_raises(Railpress::ThemePackage::Invalid) { Themes::Storage.load(first) }
  end
  test "native theme constraints reject invalid state and orphan overlay references" do
    package = stage
    assert_raises(ActiveRecord::StatementInvalid) { ThemeState.first.update_columns(default_key: "avatar") }
    assert_raises(ActiveRecord::StatementInvalid) { ThemeState.first.update_columns(active_installation_id: package.id, active_overlay_id: nil) }
    assert_raises(ActiveRecord::InvalidForeignKey) { ThemeOverlay.insert_all!([ { theme_installation_id: package.id, author_id: 999999999, number: 2, options: {}, media_details: {}, created_at: Time.current } ]) }
    assert_raises(ActiveRecord::RecordNotUnique) { ThemeOverlay.create!(theme_installation: package, author: @owner, number: 1, options: {}, media_details: {}) }
    assert_nil ThemeState.first.reload.active_installation_id
  end
end
