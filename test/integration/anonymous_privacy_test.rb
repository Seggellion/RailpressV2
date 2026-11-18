require "test_helper"
require_relative "../support/theme_test_support"
require_relative "../support/portability_test_support"
require Rails.root.join("lib/railpress/dusk_package")

class AnonymousPrivacyTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  include PortabilityTestSupport

  test "new sites opt in while the database migration default preserves existing sites" do
    assert Site.new.privacy_first_anonymous?
    assert_equal false, Site.type_for_attribute("privacy_first_anonymous").cast(Site.columns_hash.fetch("privacy_first_anonymous").default)
    assert Site.first.privacy_first_anonymous?
    refute Site.new(privacy_first_anonymous: false).privacy_first_anonymous?
    assert_raises(ActiveRecord::StatementInvalid) { Site.where(id: Site.first.id).update_all(privacy_revision: -1) }
  end

  test "anonymous route matrix has no session cookie or automatic external resources with or without supplied cookies" do
    item = public_content(slug: "private-policy-post")
    hidden = draft(slug: "privacy-private")
    rows = []
    [ "/", "/blog", "/blog/#{item.slug}", "/search?q=Caf", "/search?page=1", "/robots.txt", "/sitemap.xml", "/feed.xml", "/api/public/v1/news.json", "/missing-page", "/blog/#{hidden.slug}" ].each do |path|
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.https!
      client.get(path, headers: { "Cookie" => "unrelated_visitor=not-used" })
      assert_includes [ 200, 301, 404 ], client.response.status
      assert_nil client.response.headers["Set-Cookie"], path
      assert_includes client.response.headers["Content-Security-Policy"], "connect-src 'none'", path
      assert_equal "no-referrer", client.response.headers["Referrer-Policy"]
      refute_includes client.response.body, hidden.title if path.include?(hidden.slug)
      doc = Nokogiri::HTML(client.response.body)
      assert_empty doc.css("iframe,object,embed,meta[name='csrf-token']")
      assert_empty doc.css("img[src^='http'],script[src^='http'],link[rel='stylesheet'][href^='http']")
      rows << { path: path, status: client.response.status, cookie: false }
    end
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-anonymous-routes.json"), JSON.pretty_generate(rows))
  end

  test "Owner privacy controls reject every other role malformed value missing CSRF and stale revision" do
    [ @editor, @author, create_account("administrator") ].each do |user|
      client = ActionDispatch::Integration::Session.new(Rails.application); client.https!
      sign_in(client, user)
      client.get("/admin/privacy"); assert_equal 403, client.response.status
    end
    sign_in
    csrf = csrf_token_for(self, "/admin/privacy")
    patch "/admin/privacy", params: { authenticity_token: csrf, revision: 0, privacy: { enabled: "false" } }
    assert_response :unprocessable_entity
    patch "/admin/privacy", params: { revision: 0, privacy: { enabled: "0" } }
    assert_response :unprocessable_entity
    csrf = csrf_token_for(self, "/admin/privacy")
    patch "/admin/privacy", params: { authenticity_token: csrf, revision: 0, privacy: { enabled: "0" } }
    assert_response :see_other
    refute Site.first.privacy_first_anonymous?
    assert_equal 1, Site.first.privacy_revision
    csrf = csrf_token_for(self, "/admin/privacy")
    patch "/admin/privacy", params: { authenticity_token: csrf, revision: 0, privacy: { enabled: "1" } }
    assert_response :conflict
    refute Site.first.privacy_first_anonymous?
    assert ActivityEvent.exists?(action: "identity.site_updated")
  end

  test "concurrent privacy writes permit exactly one expected revision" do
    outcomes = parallel_results(2) do |index|
      Privacy::Policy.configure!(actor: User.find(@owner.id), revision: 0, value: index.zero? ? "0" : "1")
      :saved
    rescue Privacy::Conflict
      :conflict
    end
    assert_equal 1, outcomes.count(:saved)
    assert_equal 1, outcomes.count(:conflict)
    assert_equal 1, Site.first.privacy_revision
    assert_includes [ true, false ], Site.first.privacy_first_anonymous?
  end

  test "auth CSRF cookie protected staff and session revocation survive anonymous policy" do
    get "/login"
    assert response.headers["Set-Cookie"].present?
    assert_includes response.headers["Set-Cookie"], "secure"
    assert_select 'meta[name="csrf-token"]', count: 1
    sign_in
    get "/admin/privacy"; assert_response :success
    Privacy::Policy.configure!(actor: @owner, revision: Site.first.privacy_revision, value: "0")
    get "/admin/privacy"; assert_response :success
    Privacy::Policy.configure!(actor: @owner, revision: Site.first.privacy_revision, value: "1")
    get "/admin/privacy"; assert_response :success
    csrf = csrf_token_for(self, "/admin/privacy")
    delete "/logout", params: { authenticity_token: csrf }
    get "/admin/privacy"; assert_response :see_other
  end

  test "OFF is explicit and does not introduce tracking while stale Owner authority is denied" do
    Privacy::Policy.configure!(actor: @owner, revision: 0, value: "0")
    get "/"
    assert_response :success
    refute_includes response.headers["Content-Security-Policy"], "connect-src 'none'"
    assert_nil response.headers["Set-Cookie"]
    stale = User.find(@owner.id)
    User.where(id: @owner.id).update_all(auth_version: stale.auth_version + 1)
    assert_raises(Identity::Capabilities::Denied) { Privacy::Policy.configure!(actor: stale, revision: 1, value: "1") }
    refute Site.first.privacy_first_anonymous?
  end

  test "Dusk appearance and alternate theme retain anonymous no-storage policy and private preview" do
    directory = File.join(@private_root, "privacy-dusk")
    Railpress::DuskPackage.build(directory, root: Rails.root, signer: @signer)
    dusk = Themes::Manager.stage!(actor: @owner, directory: directory)
    activate(dusk)
    %w[light dark system].each do |mode|
      overlay = Themes::Manager.overlay!(actor: @owner, installation: dusk, attributes: { appearance_mode: mode })
      activate(dusk, overlay)
      get "/"
      assert_response :success
      assert_nil response.headers["Set-Cookie"]
      assert_select "body[data-dusk-appearance='#{mode}']"
    end
    harbor = stage
    overlay = Themes::Manager.overlay!(actor: @owner, installation: harbor, attributes: { footer: "PRIVATE A06 PREVIEW" })
    sign_in
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/#{harbor.id}/preview", params: { authenticity_token: csrf, overlay_id: overlay.id }
    get "/"; assert_includes response.body, "PRIVATE A06 PREVIEW"
    guest = ActionDispatch::Integration::Session.new(Rails.application); guest.https!; guest.get("/")
    refute_includes guest.response.body, "PRIVATE A06 PREVIEW"
    assert_nil guest.response.headers["Set-Cookie"]
  end

  test "external media is an explicit safe link without automatic embedded tracking" do
    blocks = ContentBlocks::Schema.normalize([ { type: "external_media", heading: "A demonstration", url: "https://media.example.invalid/watch?id=1" } ])
    html = ContentBlocks::Renderer.new(details: {}, context: {}).render(blocks)
    doc = Nokogiri::HTML.fragment(html)
    assert_empty doc.css("iframe,script,img,source,video,audio,object,embed")
    assert_equal "https://media.example.invalid/watch?id=1", doc.at_css("a")["href"]
    assert_includes doc.at_css("a")["rel"], "noreferrer"
    assert_includes doc.text, "Nothing is embedded or preloaded"
    %w[javascript:alert(1) //evil.invalid /local].each do |url|
      assert_raises(ContentBlocks::Schema::Invalid) { ContentBlocks::Schema.normalize([ { type: "external_media", url: url } ]) }
    end
    assert_empty Nokogiri::HTML.fragment(Editorial::RichText.clean('<iframe src="https://tracker.invalid"></iframe>')).css("iframe")
  end

  test "external media editor preserves disclosed destinations and rejects unsafe replacements" do
    item = draft(actor: @owner, blocks: [ { type: "external_media", heading: "Original disclosure", url: "https://media.example.invalid/original" } ])
    sign_in
    token = csrf_token_for(self, edit_admin_content_path(item))
    assert_select "textarea[name=?]", "content[blocks][0][heading]", text: "Original disclosure"
    assert_select "textarea[name=?]", "content[blocks][0][url]", text: "https://media.example.invalid/original"
    fields = { "0" => { type: "external_media", heading: "Changed disclosure", url: "https://media.example.invalid/changed" } }
    patch admin_content_path(item), params: { authenticity_token: token, version: item.reload.lock_version, content: { blocks_present: "1", blocks: fields } }
    assert_response :see_other
    token = csrf_token_for(self, edit_admin_content_path(item))
    assert_select "textarea[name=?]", "content[blocks][0][url]", text: "https://media.example.invalid/changed"
    assert_equal "Changed disclosure", item.reload.blocks.first["heading"]
    fields["0"][:url] = "javascript:alert(1)"
    patch admin_content_path(item), params: { authenticity_token: token, version: item.lock_version, content: { blocks_present: "1", blocks: fields } }
    assert_response :unprocessable_entity
    assert_equal "https://media.example.invalid/changed", item.reload.blocks.first["url"]
  end

  test "in-process diagnostic records actual public responses but does not attest browser or host logs" do
    Current.reset
    report = Privacy::Diagnostics.call(Site.first)
    assert report["checks_pass"], report["routes"].inspect
    assert_equal "NOT TESTED", report["browser_execution"]
    assert_equal "UNKNOWN", report["host_proxy_IP_logs"]
    Privacy::Diagnostics.write!(report)
    assert_equal report, Privacy::Diagnostics.read(Site.first)
    File.write(Privacy::Diagnostics.path, "[]")
    assert_nil Privacy::Diagnostics.read(Site.first)
    Privacy::Diagnostics.write!(report)
    Privacy::Policy.configure!(actor: @owner, revision: 0, value: "0")
    assert_nil Privacy::Diagnostics.read(Site.first)
  end

  test "approved archive privacy change stages privately activates explicitly and reverses safely" do
    manifest = portable_manifest
    manifest["version"] = 3
    manifest["site"]["privacy_first_anonymous"] = false
    session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id)
    Portability::Worker.perform!(batch)
    assert_includes batch.reload.report["privacy"], "v3"
    decisions = portable_decisions(manifest).merge("settings" => "apply_nonsensitive")
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: decisions)
    Portability::Worker.perform!(batch)
    assert Site.first.privacy_first_anonymous?
    Portability::Activation.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version, content_refs: [], menus: false, settings: true, appearance: false)
    Portability::Worker.perform!(batch)
    assert_equal "complete", batch.reload.state
    refute Site.first.privacy_first_anonymous?
    Portability::Reversal.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version)
    Portability::Worker.perform!(batch)
    assert_equal "reversed", batch.reload.state
    assert Site.first.privacy_first_anonymous?
  end

  test "old archive settings activation preserves destination anonymous mode" do
    manifest = portable_manifest
    session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id)
    Portability::Worker.perform!(batch)
    decisions = portable_decisions(manifest).merge("settings" => "apply_nonsensitive")
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version, decisions: decisions)
    Portability::Worker.perform!(batch)
    Portability::Activation.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version, content_refs: [], menus: false, settings: true, appearance: false)
    Portability::Worker.perform!(batch)
    assert_equal "complete", batch.reload.state
    assert Site.first.privacy_first_anonymous?
    assert_equal 0, Site.first.privacy_revision
  end

  test "archive v3 carries policy and old v2 cannot silently overwrite it" do
    scope = { "mode" => "owner_private", "content_ids" => Content.pluck(:id), "revisions" => false, "menus" => false, "appearance" => false }
    Site.first.update!(privacy_first_anonymous: false)
    snapshot = Portability::Snapshot.new(Site.first, scope)
    data = snapshot.capture
    assert_equal 3, data["version"]
    assert_equal false, data.dig("site", "privacy_first_anonymous")
    Portability::Format.check!(data, snapshot.payloads)
    data["site"]["privacy_first_anonymous"] = "false"
    assert_raises(Portability::Format::Invalid) { Portability::Format.check!(data, snapshot.payloads) }
    legacy = portable_manifest
    assert_equal 2, legacy["version"]
    Portability::Format.check!(legacy, {})
    digest = Portability::Imports.destination_digest(Site.first)
    Site.first.update!(privacy_first_anonymous: true)
    refute_equal digest, Portability::Imports.destination_digest(Site.first)
    assert_equal true, Site.first.privacy_first_anonymous?
  end
end
