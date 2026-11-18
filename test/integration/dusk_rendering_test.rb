require "test_helper"
require_relative "../support/theme_test_support"
require Rails.root.join("lib/railpress/dusk_package")

class DuskRenderingTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  def dusk_package(mutate: nil)
    directory = File.join(@private_root, "original-dusk-#{SecureRandom.hex(6)}")
    Railpress::DuskPackage.build(directory, root: Rails.root, signer: @signer)
    if mutate
      manifest = JSON.parse(File.read(File.join(directory, "manifest.json")))
      mutate.call(manifest, directory)
      Railpress::ThemeFixture.sign(directory, manifest, @signer)
    end
    Themes::Manager.stage!(actor: @owner, directory: directory)
  end
  test "fresh Dusk has usable empty home archive search and 404 with core policy" do
    package = dusk_package; activate(package)
    [ [ "/", 200, "home" ], [ "/blog", 200, "empty" ], [ "/search?q=absent", 200, "empty" ], [ "/absent/path", 404, "not_found" ] ].each do |path, status, family|
      get path
      assert_equal status, response.status
      assert_select "[data-dusk-family=#{family}]", count: 1
      assert_select "main#main", count: 1
      assert_select "h1", count: 1
      assert_select 'a[href="#main"]', text: "Skip to content"
      assert_select 'header nav[aria-label="Primary"] a[href="/blog"]'
      assert_select "script[src]", count: 1
      script = Nokogiri::HTML(response.body).at_css("script[src]")
      assert_includes response.headers["Content-Security-Policy"], "'nonce-#{script['nonce']}'"
      assert_select "script:not([src]):not([type='application/ld+json'])", count: 0
      assert_select 'head link[rel="canonical"]', count: status == 404 ? 0 : 1
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    end
    assert_equal "dusk", package.theme_key
    assert_raises(Themes::Manager::Protected) { Themes::Manager.remove!(actor: @owner, installation: package) }
  end
  test "published families pagination taxonomy and static home preserve private fences and canonical ownership" do
    package = dusk_package; activate(package)
    topic = term("category", "Field notes"); tag = term("tag", "Design")
    first = nil
    13.times do |index|
      entry = public_content(slug: "dusk-#{index}")
      change(entry, attributes: { term_ids: [ topic.id, tag.id ] })
      entry = change(entry, "publish")
      first ||= entry
    end
    hidden = draft(slug: "hidden", title: "PRIVATE DUSK CANARY")
    change(first, attributes: { title: "WORKING DUSK CANARY" })
    page = draft("Page", slug: "about", title: "A local studio")
    change(page, "publish")
    matrix = []
    [ [ "/about", "page" ], [ "/blog/dusk-0", "post" ], [ "/blog", "archive" ], [ "/blog?page=2", "archive" ], [ "/category/field-notes", "taxonomy" ], [ "/tag/design", "taxonomy" ], [ "/search?q=Caf", "search" ] ].each do |path, family|
      get path, headers: { "Host" => "attacker.invalid", "X-Forwarded-Host" => "attacker.invalid" }
      assert_response :ok
      assert_select "[data-dusk-family=#{family}]"
      refute_match(/PRIVATE DUSK CANARY|WORKING DUSK CANARY|attacker.invalid/, response.body)
      assert_select 'head link[rel="canonical"]', count: 1
      matrix << observed_head.merge("path" => path)
    end
    get "/blog"; assert_select ".dusk-card", count: 12
    assert_select 'a[rel="next"][href="/blog?page=2"]'
    get "/blog?page=2"; assert_select ".dusk-card", count: 1
    get "/blog/#{hidden.slug}"; assert_response :not_found
    site.update!(homepage_content_id: page.id, home_mode: "static")
    get "/"; assert_select '[data-dusk-family="front"]'; assert_select "h1", text: page.title
    site.update!(home_mode: "blog")
    get "/"; assert_select '[data-dusk-family="archive"]'
    assert_select 'link[rel="canonical"][href="https://publishing.example.invalid/"]'
    path = Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M07')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-dusk-head-matrix.json")
    File.write(path, JSON.pretty_generate(matrix) + "\n")
  end
  test "Dusk overlay preview is session private and immutable vendor bytes survive activation" do
    package = dusk_package; activate(package)
    before = Themes::Storage.load(package).files
    logo = upload_media(actor: @owner)
    overlay = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { brand_label: "Aster & Co", palette: "woodland", font: "system_sans", layout: "reading", header_style: "centered", footer_style: "compact", footer: "OWNER DUSK PREVIEW", logo_id: logo.id })
    sign_in
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/#{package.id}/preview", params: { overlay_id: overlay.id, authenticity_token: csrf }
    get "/"
    assert_response :ok
    assert_includes response.body, "OWNER DUSK PREVIEW"
    assert_select ".dusk-header-centered.dusk-palette-woodland.dusk-font-system_sans"
    assert_select ".dusk-footer-compact"
    assert_select ".dusk-brand", text: "Aster & Co"
    assert_select ".dusk-brand img[alt]"
    assert_select 'link[rel="canonical"],script[type="application/ld+json"]', count: 0
    assert_includes response.headers["Cache-Control"], "no-store"
    other = ActionDispatch::Integration::Session.new(Rails.application); other.https!; other.get("/")
    refute_includes other.response.body, "OWNER DUSK PREVIEW"
    refute_includes other.response.body, "Aster &amp; Co"
    assert_equal before, Themes::Storage.load(package).files
    activate(package, overlay)
    get "/"; assert_includes response.body, "OWNER DUSK PREVIEW"
    assert_equal before, Themes::Storage.load(package).files
    %w[canonical robots javascript palette_css].each do |key|
      assert_raises(ArgumentError) { Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { key => "https://attacker.invalid" }) }
    end
    assert_raises(ArgumentError) { Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { brand_label: "<script>" }) }
    assert_raises(ArgumentError) { Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { header_style: "onclick" }) }
  end
  test "long Unicode legal and documentation records escape text and expose no working content" do
    package = dusk_package; activate(package)
    item = draft("Page", slug: "privacy", title: "Privacy — 日本語 Café 🌒", body: "<h2>Our policy</h2><p>#{"Longword_日本語_" * 1000}</p>")
    change(item, "publish")
    get "/privacy"; assert_response :ok
    assert_select "h1", text: "Privacy — 日本語 Café 🌒"
    assert_select ".dusk-prose h2", text: "Our policy"
    refute_select = Nokogiri::HTML(response.body).css(".dusk-prose script")
    assert_empty refute_select
    get "/search", params: { q: '<script>alert("x")</script>' }
    assert_response :ok
    assert_select "script:not([src]):not([type='application/ld+json'])", count: 0
    assert_select 'input[name="q"]' do |nodes|
      assert_equal '<script>alert("x")</script>', nodes.first["value"]
    end
  end
  test "brochure blocks missing media and recent posts retain semantic portable output" do
    package = dusk_package; activate(package)
    asset = upload_media(actor: @owner)
    blocks = %w[hero services about testimonial faq contact_cta contact].flat_map { |key| ContentBlocks::Patterns.fetch(key) }
    blocks << { "type" => "image", "media_id" => asset.id, "caption" => "An original fixture" }
    item = draft("Page", actor: @owner, slug: "services", blocks: blocks)
    item = change(item, "publish")
    site.update!(home_mode: "static", homepage_content_id: item.id)
    public_content(slug: "recent-visible", title: "Approved recent story")
    draft(slug: "recent-private", title: "RECENT PRIVATE CANARY")
    get "/"; assert_response :ok
    assert_select ".content-hero"
    assert_select '[aria-label="Services and features"] article', count: 2
    assert_select "blockquote"; assert_select "details summary"
    assert_select ".dusk-recent h3", text: "Approved recent story"
    refute_includes response.body, "RECENT PRIVATE CANARY"
    assert_select "figure img[alt][width][height][loading=lazy]"
    asset.blob.service.delete(asset.blob.key)
    get "/"; assert_response :ok
    assert_select ".media-unavailable[role=img]"
  end
  test "nested navigation contract is frozen bounded local and keyboard native without M08 persistence" do
    package = dusk_package
    bundle = Themes::Storage.load(package)
    item = Themes::Navigation.method(:item)
    leaf = item.call(label: "日本語 & guide", url: "/guide")
    branch = item.call(label: "Learn", url: "/docs", children: [ leaf ])
    slots = Themes::Navigation.slots(primary: [ branch ], footer: [ leaf ], documentation: [ leaf ])
    context = Themes::Context.build(site: site, family: "page", presenter: ContentPresenter.new(change(draft("Page", slug: "docs"), "publish")), presenters: [], query: nil, title: "Docs", page: 1, more: false, path: "/docs", options: {}, navigation: slots)
    output = Railpress::ThemeRenderer.render(bundle, context)
    doc = Nokogiri::HTML5.fragment(output.navigation)
    assert_equal 2, doc.css("details.dusk-submenu[data-disclosure] summary").length
    assert_equal 2, doc.css('a[href="/guide"]').length
    assert_equal "Learn", doc.at_css("summary").text
    assert_includes output.body, 'aria-label="Documentation"'
    assert context.navigation.frozen?
    assert_raises(FrozenError) { context.navigation.primary.first.label << "leak" }
    [ "//evil.invalid", "javascript:alert(1)", "/bad\nheader", "https://evil.invalid", "/a\\b" ].each do |url|
      assert_raises(ArgumentError) { item.call(label: "Bad", url: url) }
    end
    deep = leaf
    4.times { deep = item.call(label: "Deep", url: "/docs", children: [ deep ]) }
    assert_raises(ArgumentError) { Themes::Navigation.slots(primary: [ deep ]) }
  end
  test "broken Dusk component preserves core recovery and last good identity" do
    good = stage; activate(good)
    broken = dusk_package(mutate: ->(manifest, directory) { Railpress::ThemeFixture.replace(manifest, directory, "templates/navigation.html.erb", '<% raise "synthetic Dusk failure" if theme.site.title == "Synthetic Railpress" %><header>Smoke safe</header>') })
    activate(broken)
    get "/"; assert_response :service_unavailable
    assert_select "script,link[rel=canonical]", count: 0
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_equal broken.id, ThemeState.first.active_installation_id
    sign_in; get "/admin/themes"; assert_response :ok
    assert_includes response.headers["Content-Security-Policy"], "script-src 'self'"
    Themes::Manager.revert!(actor: @owner, version: ThemeState.first.lock_version)
    get "/"; assert_response :ok
    assert_equal good.id, ThemeState.first.active_installation_id
  end
  test "every palette typography and layout combination renders all declared families in production smoke context" do
    package = dusk_package; bundle = Themes::Storage.load(package)
    source = bundle.files
    %w[afterglow woodland slate].product(%w[system_serif system_sans], %w[studio reading]).each do |palette, font, layout|
      Railpress::ThemePackage::FAMILIES.each do |family|
        context = Railpress::ThemeRenderer.fixture_context(family, { "palette" => palette, "font" => font, "layout" => layout })
        output = Railpress::ThemeRenderer.render(bundle, context)
        assert output.body.valid_encoding?
        assert_includes output.navigation, "dusk-palette-#{palette}"
        assert_includes output.footer, "dusk-font-#{font}"
      end
    end
    assert_equal source, Themes::Storage.load(package).files
  end
end
