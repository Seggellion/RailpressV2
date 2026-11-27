require "test_helper"
require_relative "../support/theme_test_support"
class QualificationThemeIsolationTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  test "two owner previews anonymous and nonowner concurrent requests never exchange customizations or private content" do
    dusk = stage("dusk"); activate(dusk)
    harbor = stage
    second = User.create!(owner_attributes("second_owner").merge(role: "owner"))
    assets = [ upload_media(actor: @owner), upload_media(actor: second) ]
    owners = [ @owner, second ]
    overlays = owners.each_with_index.map { |actor, i| Themes::Manager.overlay!(actor: actor, installation: harbor, attributes: { footer: "PREVIEW OWNER #{i} PRIVATE CANARY", logo_id: assets[i].id, favicon_id: assets[i].id }) }
    item = public_content(slug: "qualified-live", title: "APPROVED PUBLIC TITLE")
    change(item, attributes: { title: "PRIVATE WORKING CANARY", body: "PRIVATE WORKING BODY" })
    hidden = [ draft(slug: "qualified-secret", title: "NEVER PUBLIC CANARY"), public_content(slug: "qualified-private", visibility: "private", title: "PRIVATE PUBLISHED CANARY") ]
    clients = 4.times.map { client = ActionDispatch::Integration::Session.new(Rails.application); client.https!; client }
    [ @owner, second, @author ].each_with_index { |user, i| sign_in(clients[i], user) }
    owners.each_index do |i|
      csrf = csrf_token_for(clients[i], "/admin/themes")
      clients[i].post("/admin/themes/#{harbor.id}/preview", params: { overlay_id: overlays[i].id, authenticity_token: csrf })
      assert_equal 303, clients[i].response.status
    end
    results = []
    5.times do
      responses = parallel_results(4) do |i|
        clients[i].get("/blog/qualified-live", params: { theme: "harbor", overlay_id: overlays[0].id })
        { client: i, status: clients[i].response.status, body: clients[i].response.body, cache: clients[i].response.headers["Cache-Control"] }
      end
      responses.each do |row|
        i = row[:client]
        assert_equal 200, row[:status]
        assert_includes row[:body], "APPROVED PUBLIC TITLE"
        refute_match(/PRIVATE WORKING CANARY|PRIVATE WORKING BODY|NEVER PUBLIC CANARY|PRIVATE PUBLISHED CANARY/, row[:body])
        if i < 2
          assert_includes row[:body], "PREVIEW OWNER #{i} PRIVATE CANARY"
          refute_includes row[:body], "PREVIEW OWNER #{1-i} PRIVATE CANARY"
          assert_includes row[:cache], "no-store"
          doc = Nokogiri::HTML(row[:body])
          assert_empty doc.css('link[rel="canonical"],script[type="application/ld+json"]')
          assert_equal "noindex, nofollow", doc.at_css('meta[name="robots"]')["content"]
        else
          refute_match(/PREVIEW OWNER [01] PRIVATE CANARY/, row[:body])
          assert_includes row[:body], 'data-theme="dusk"'
        end
        results << { client: i, status: row[:status], own_preview: i < 2, other_canary_exposed: false, private_content_exposed: false }
      end
    end
    clients.each_with_index do |client, i|
      hidden.each { |record| client.get("/blog/#{record.slug}"); assert_equal 404, client.response.status }
      overlays.each_with_index do |overlay, owner|
        client.get("/theme-media/#{overlay.id}/logo")
        assert_equal i == owner ? 200 : 404, client.response.status
        assert_includes client.response.headers["Cache-Control"], "no-store" if i == owner
      end
      client.get("/theme-preview-assets/harbor/#{harbor.version}/#{harbor.digest}/public.css")
      assert_equal i < 2 ? 200 : 404, client.response.status
      assert_includes client.response.headers["Cache-Control"], "no-store"
      assert_includes client.response.headers["X-Robots-Tag"], "noindex"
      client.get("/theme-assets/harbor/#{harbor.version}/#{harbor.digest}/public.css")
      assert_equal 404, client.response.status
    end
    # Real role/auth-version revocation, not a hand-edited session cookie.
    Identity::ManageUsers.change_role!(actor: second, user: @owner, role: "author")
    clients[0].get("/blog/qualified-live")
    assert_equal 200, clients[0].response.status
    refute_match(/PREVIEW OWNER [01] PRIVATE CANARY/, clients[0].response.body)
    clients[0].get("/theme-media/#{overlays[0].id}/logo"); assert_equal 404, clients[0].response.status
    clients[0].get("/theme-preview-assets/harbor/#{harbor.version}/#{harbor.digest}/public.css")
    assert_equal 404, clients[0].response.status
    File.write(Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-concurrent-security-proof.json"), JSON.pretty_generate(scope: "twenty concurrent HTTP responses;two owners/nonowner/anonymous plus private routes/media/assets/revocation", observations: results) + "\n")
  end
  test "main thread cached state can be stale after exactly one activation wins without leaking a pair" do
    dusk = stage("dusk"); activate(dusk)
    harbor = stage
    alternate = Themes::Manager.overlay!(actor: @owner, installation: harbor, attributes: { footer: "Second overlay" })
    prepare_preview(harbor); prepare_preview(harbor, alternate)
    ThemeState.cache do
      previous = ThemeState.first
      results = parallel_results(2) do |i|
        begin
          Themes::Manager.activate!(actor: User.find(@owner.id), installation: ThemeInstallation.find(harbor.id), overlay: ThemeOverlay.find(i.zero? ? harbor.theme_overlays.first.id : alternate.id), version: previous.lock_version)
          "activated"
        rescue Themes::Manager::Conflict
          "conflict"
        end
      end
      cached = ThemeState.first
      fresh = ThemeState.first.reload
      assert_equal %w[activated conflict], results.sort
      assert_equal dusk.id, cached.active_installation_id
      assert_equal harbor.id, fresh.active_installation_id
      assert_equal harbor.id, fresh.active_overlay.theme_installation_id
      assert_equal dusk.id, fresh.previous_installation_id
      File.write(Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-state-cache-proof.json"), JSON.pretty_generate(legacy_cached: cached.active_installation.public_identity, fresh: fresh.active_installation.public_identity, results: results, active_pair_consistent: true) + "\n")
    end
  end
end
