require "test_helper"
require_relative "../support/theme_test_support"
require_relative "../support/portability_test_support"
require Rails.root.join("lib/railpress/dusk_package")

class DuskAppearanceTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  include PortabilityTestSupport

  def dusk(legacy: false)
    directory = File.join(@private_root, "appearance-#{SecureRandom.hex(6)}")
    Railpress::DuskPackage.build(directory, root: Rails.root, signer: @signer)
    if legacy
      manifest = JSON.parse(File.read(File.join(directory, "manifest.json")))
      manifest["version"] = "1.1.3"
      manifest["options"].delete("appearance_modes")
      manifest["options"].delete("artwork_styles")
      Railpress::ThemeFixture.sign(directory, manifest, @signer)
    end
    Themes::Manager.stage!(actor: @owner, directory: directory)
  end

  test "fresh mode is system while legacy upgrade appends a light snapshot with retained media and options" do
    fresh = dusk
    assert_equal "system", fresh.theme_overlays.first.options["appearance_mode"]
    old = dusk(legacy: true)
    logo = upload_media(actor: @owner)
    original = Themes::Manager.overlay!(actor: @owner, installation: old, attributes: { palette: "woodland", footer: "Retained footer", logo_id: logo.id, favicon_id: logo.id })
    activate(old, original)
    assert_nil original.options["appearance_mode"]
    before = Themes::Storage.load(old).files
    # Remove only the never-active synthetic candidate row so staging can exercise
    # first-time upgrade initialization; installed package bytes remain immutable.
    ThemeOverlay.where(theme_installation: fresh).delete_all
    upgraded = dusk
    copied = upgraded.theme_overlays.first
    assert_equal original.options.merge("appearance_mode" => "light", "artwork_style" => "none"), copied.options
    assert_equal original.media_details, copied.media_details
    assert_equal 1, MediaReference.where(theme_overlay: copied).count
    assert_equal old.id, ThemeState.first.active_installation_id
    activate(upgraded, copied)
    get "/"
    assert_select 'body[data-dusk-appearance="light"][data-dusk-palette="woodland"]'
    assert_equal before, Themes::Storage.load(old).files
    assert_nil original.reload.options["appearance_mode"]
  end

  test "all modes preserve public route head sitemap navigation content and storage invariants" do
    package = dusk
    public_content(slug: "visible", title: "A public journal")
    page = change(draft("Page", slug: "docs", title: "Documentation — 日本語", body: "<h2>Native guide</h2><pre><code>safe example</code></pre>"), "publish")
    draft(slug: "secret", title: "PRIVATE APPEARANCE CANARY")
    baseline = nil
    matrix = {}
    %w[light dark system].each do |mode|
      overlay = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { appearance_mode: mode })
      activate(package, overlay)
      rows = [ "/", "/docs", "/blog/visible", "/blog", "/search?q=public", "/search?q=absent", "/absent/path", "/blog/secret" ].map do |path|
        get path
        doc = Nokogiri::HTML(response.body)
        assert_select "body[data-dusk-appearance=#{mode}]"
        assert_nil response.headers["Set-Cookie"]
        refute_includes response.body, "PRIVATE APPEARANCE CANARY"
        assert_select 'script:not([src]):not([type="application/ld+json"])', count: 0
        [ path, observed_head, doc.css("header a,footer a").map { |a| [ a.text, a["href"] ] }, doc.at_css("main").text, sitemap_urls ]
      end
      baseline ||= rows
      assert_equal baseline, rows
      matrix[mode] = rows
      assert_equal page.id, Content.find(page.id).id
    end
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'A03')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-appearance-equivalence.json"), JSON.pretty_generate(matrix) + "\n")
  end

  test "appearance preview is private and activation retains optimistic conflict and recovery rules" do
    package = dusk
    light = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { appearance_mode: "light" })
    activate(package, light)
    dark = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { appearance_mode: "dark" })
    assert_raises(Themes::Manager::Protected) { Themes::Manager.activate!(actor: @owner, installation: package, overlay: dark, version: ThemeState.first.lock_version) }
    sign_in
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/#{package.id}/preview", params: { overlay_id: dark.id, authenticity_token: csrf }
    assert_response :see_other
    get "/"
    assert_select 'body[data-dusk-appearance="dark"]'
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select 'link[rel="canonical"],script[type="application/ld+json"]', count: 0
    other = ActionDispatch::Integration::Session.new(Rails.application)
    other.https!
    other.get "/"
    assert_includes other.response.body, 'data-dusk-appearance="light"'
    version = ThemeState.first.lock_version
    Themes::Manager.activate!(actor: @owner, installation: package, overlay: dark, version: version)
    assert_raises(Themes::Manager::Conflict) { Themes::Manager.activate!(actor: @owner, installation: package, overlay: light, version: version) }
    harbor = stage
    activate(harbor)
    Themes::Manager.revert!(actor: @owner, version: ThemeState.first.lock_version)
    assert_equal dark.id, ThemeState.first.active_overlay_id
    assert_equal "dark", ThemeState.first.active_overlay.options["appearance_mode"]
    get "/admin"
    assert_select "body.core[data-dusk-appearance]", count: 0
    assert_select 'link[href*="protected_dark"]', count: 1
  end

  test "simultaneous mode activations have one winner without mixed state" do
    package = dusk
    activate(package)
    overlays = %w[light dark].map { |mode| Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { appearance_mode: mode }) }
    overlays.each { |overlay| prepare_preview(package, overlay) }
    version = ThemeState.first.lock_version
    results = parallel_results(2) do |index|
      begin
        Themes::Manager.activate!(actor: User.find(@owner.id), installation: ThemeInstallation.find(package.id), overlay: ThemeOverlay.find(overlays[index].id), version: version)
        "activated"
      rescue Themes::Manager::Conflict
        "conflict"
      end
    end
    assert_equal %w[activated conflict], results.sort
    state = ThemeState.first.reload
    assert_equal version + 1, state.lock_version
    assert_includes overlays.map(&:id), state.active_overlay_id
    assert_equal package.id, state.active_installation_id
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'A03')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-appearance-concurrency.json"), JSON.pretty_generate(results: results, version: state.lock_version, mode: state.active_overlay.options["appearance_mode"]) + "\n")
  end

  test "mode validation and direct role denials preserve the single authority" do
    package = dusk
    [ nil, "", "auto", "Dark", "dark\n", [ "dark" ], { "value" => "dark" }, "<script>" ].each do |mode|
      assert_raises(ArgumentError) { Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { appearance_mode: mode }) }
    end
    harbor = stage
    assert_raises(ArgumentError) { Themes::Manager.overlay!(actor: @owner, installation: harbor, attributes: { appearance_mode: "dark" }) }
    assert_equal "light", Themes::Appearance.mode(package.manifest, {})
    %w[administrator editor author].each do |role|
      actor = User.create!(username: "appearance-#{role}", email: "appearance-#{role}@example.invalid", password: PASSWORD, password_confirmation: PASSWORD, role: role)
      assert_raises(Identity::Capabilities::Denied) { Themes::Manager.overlay!(actor: actor, installation: package, attributes: { appearance_mode: "dark" }) }
      sign_in(self, actor)
      csrf = csrf_token_for(self, "/admin")
      post "/admin/themes/#{package.id}/overlay", params: { overlay: { appearance_mode: "dark" }, authenticity_token: csrf }
      assert_response :forbidden
    end
    assert_equal 1, package.theme_overlays.count
  end

  test "appearance palette combinations render every family with immutable assets" do
    package = dusk
    bundle = Themes::Storage.load(package)
    %w[light dark system].product(%w[afterglow woodland slate], Railpress::ThemePackage::FAMILIES).each do |mode, palette, family|
      output = Railpress::ThemeRenderer.render(bundle, Railpress::ThemeRenderer.fixture_context(family, { "appearance_mode" => mode, "palette" => palette }))
      assert output.body.valid_encoding?
      assert_includes output.navigation, "dusk-palette-#{palette}"
    end
    assert_equal bundle.files, Themes::Storage.load(package).files
    css = bundle.files.fetch("assets/public.css")
    assert_includes css, "prefers-color-scheme:dark"
    assert_includes css, "color-scheme:dark"
    refute_match(/localStorage|sessionStorage|document.cookie|@import|url\s*\(/, css)
  end

  test "portable appearance roundtrip stages exact mode without silently activating it" do
    package = dusk
    overlay = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { appearance_mode: "dark", palette: "slate" })
    activate(package, overlay)
    scope = { "mode" => "public", "content_ids" => [], "history" => false, "author_labels" => {}, "media_rights" => {}, "menus" => false, "appearance" => true }
    capture = Portability::Snapshot.new(site, scope)
    exported = capture.capture
    bytes = Railpress::SiteArchive.build(exported, capture.payloads)
    imported, payloads = Railpress::SiteArchive.read(bytes)
    assert_equal exported, Portability::Format.check!(imported, payloads)
    assert_equal "dark", imported["appearance"]["options"]["appearance_mode"]
    manifest = portable_manifest
    manifest["appearance"] = imported["appearance"]
    session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id)
    Portability::Worker.perform!(batch)
    decisions = portable_decisions(manifest).merge("appearance" => "stage_compatible")
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version, decisions: decisions)
    Portability::Worker.perform!(batch)
    assert_equal "staged", batch.reload.state
    assert_equal overlay.options, ThemeOverlay.find(batch.report.fetch("overlay_id")).options
    assert_equal overlay.id, ThemeState.first.active_overlay_id
    manifest["appearance"]["options"]["appearance_mode"] = "javascript:bad"
    assert_raises(Portability::Format::Invalid) { Portability::Format.check!(manifest, {}) }
  end
end
