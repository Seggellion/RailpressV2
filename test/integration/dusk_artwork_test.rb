require "test_helper"
require_relative "../support/theme_test_support"
require Rails.root.join("lib/railpress/dusk_package")

class DuskArtworkTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  def artwork_package
    directory = File.join(@private_root, "artwork-#{SecureRandom.hex(6)}")
    Railpress::DuskPackage.build(directory, root: Rails.root, signer: @signer)
    Themes::Manager.stage!(actor: @owner, directory: directory)
  end
  def evidence(name, value)
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'A04')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-#{name}.json"), JSON.pretty_generate(value) + "\n")
  end
  test "approved artwork is bounded immutable and every responsive derivative decodes" do
    package = artwork_package
    bundle = Themes::Storage.load(package)
    assert_equal "1.4.0", package.version
    assert_equal 17, bundle.manifest["assets"].length
    assert_operator bundle.files.values.sum(&:bytesize), :<, Railpress::ThemePackage::MAX_BYTES
    assert_equal 2 * 1024 * 1024, Railpress::ThemePackage::MAX_BYTES
    rows = bundle.manifest["assets"].filter_map do |name, asset|
      next if asset["content_type"] == "text/css"
      bytes = bundle.files.fetch(asset["file"])
      info = asset["content_type"] == "image/webp" ? Railpress::ThemeWebp.validate!(bytes) : Railpress::ImageInput.inspect!(bytes)
      assert_operator info[:width], :<=, 1024
      assert_operator info[:height], :<=, 1024
      assert_equal asset["sha256"], Digest::SHA256.hexdigest(bytes)
      assert_equal asset["content_type"], info[:type]
      { name: name, **asset, dimensions: info.slice(:width, :height) }
    end
    assert_equal 16, rows.length
    assert_equal 12, rows.count { |row| row["content_type"] == "image/webp" }
    assert_equal 4, rows.count { |row| row["content_type"] == "image/png" }
    evidence("artwork-assets", rows)
  end
  test "responsive home art preserves text SEO privacy and protected ownership across modes" do
    package = artwork_package
    page = change(draft("Page", slug: "atelier", title: "A place for ideas — 日本語", body: "<p>Ordinary editable content.</p>"), "publish")
    site.update!(home_mode: "static", homepage_content_id: page.id)
    public_content(slug: "art-note", title: "A public note")
    draft(slug: "secret-art", title: "PRIVATE ARTWORK CANARY")
    baseline = nil
    rows = []
    %w[light dark system].product(%w[editorial none]).each do |mode, art|
      overlay = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { appearance_mode: mode, artwork_style: art })
      activate(package, overlay)
      get "/"
      assert_response :ok
      doc = Nokogiri::HTML(response.body)
      actual = [ observed_head, doc.at_css("main").text, doc.css("header a,footer a").map { |link| link["href"] } ]
      baseline ||= actual
      assert_equal baseline, actual
      assert_nil response.headers["Set-Cookie"]
      refute_includes response.body, "PRIVATE ARTWORK CANARY"
      assert_select "script[src]", count: 1
      assert_select "picture", count: art == "editorial" ? 2 : 0
      if art == "editorial"
        assert_select 'picture img[alt=""][width="360"][height="240"]', count: 2
        assert_select 'picture img[loading="eager"]', count: 1
        assert_select 'picture img[loading="lazy"]', count: 1
        assert_select 'picture source[type="image/webp"][srcset][sizes]', count: 2
      end
      rows << { mode: mode, artwork: art, head: observed_head, pictures: doc.css("picture").length }
    end
    sign_in
    get "/admin"
    assert_response :ok
    assert_select "picture", count: 0
    assert_select "body.core[data-dusk-appearance]", count: 0
    evidence("artwork-policy-equivalence", rows)
  end
  test "published none and private illustrated preview never leak between sessions" do
    package = artwork_package
    plain = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { artwork_style: "none" })
    activate(package, plain)
    illustrated = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { artwork_style: "editorial" })
    sign_in
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/#{package.id}/preview", params: { authenticity_token: csrf, overlay_id: illustrated.id }
    get "/"
    assert_select "picture", count: 1
    assert_select 'link[rel="canonical"],script[type="application/ld+json"]', count: 0
    assert_includes response.headers["Cache-Control"], "no-store"
    visitor = ActionDispatch::Integration::Session.new(Rails.application)
    visitor.https!
    visitor.get "/"
    assert_equal 200, visitor.response.status
    assert_empty Nokogiri::HTML(visitor.response.body).css("picture")
    assert_equal plain.id, ThemeState.first.active_overlay_id
  end
  test "author featured content takes precedence over decorative hero without hiding media fallback" do
    package = artwork_package
    activate(package)
    media = upload_media(actor: @author)
    page = change(draft("Page", slug: "studio", featured_media_id: media.id), "publish")
    site.update!(home_mode: "static", homepage_content_id: page.id)
    get "/"
    assert_response :ok
    assert_select ".dusk-front-heading picture", count: 0
    assert_select ".dusk-featured img[alt]", count: 1
    media.blob.service.delete(media.blob.key)
    get "/"
    assert_response :ok
    assert_select ".media-unavailable[role=img]", count: 1
    assert_select ".dusk-front-heading picture", count: 0
  end
  test "signed WebP delivery is immutable nosniff local and rejects unknown assets" do
    package = artwork_package
    activate(package)
    get "/"
    doc = Nokogiri::HTML(response.body)
    srcset = doc.at_css("picture source")["srcset"]
    rows = srcset.split(",").map do |candidate|
      url = candidate.strip.split.first
      assert_match %r{\A/theme-assets/dusk/#{Regexp.escape(package.version)}/#{package.digest}/}, url
      get url
      assert_response :ok
      assert_equal "image/webp", response.media_type
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_includes response.headers["Cache-Control"], "public"
      assert_includes response.headers["Cache-Control"], "immutable"
      assert_nil response.headers["Set-Cookie"]
      assert Railpress::ThemeWebp.inspect!(response.body).fetch(:width).positive?
      { url: url, bytes: response.body.bytesize, sha256: Digest::SHA256.hexdigest(response.body) }
    end
    get "/theme-assets/dusk/#{package.version}/#{package.digest}/not-listed.webp"
    assert_response :not_found
    evidence("artwork-delivery", rows)
  end
  test "responsive resource guard rejects remote deceptive malformed and unrelated candidates" do
    bundle = Themes::Storage.load(artwork_package)
    view = Railpress::ThemeRenderer::View.new(bundle, Railpress::ThemeRenderer.fixture_context("home"))
    valid = view.theme_asset_url("hero_360")
    assert Railpress::ThemeRenderer.guard!(%(<picture><source type="image/webp" srcset="#{valid} 360w" sizes="100vw"><img src="#{view.theme_asset_url('hero_png')}" alt=""></picture>), bundle: bundle)
    [ "https://attacker.invalid/a.webp 360w", "//attacker.invalid/a.webp 360w", "data:image/webp;base64,x 360w", "javascript:alert(1) 360w", "/admin 360w", "#{valid} 1x", "#{valid} 360w,", "#{valid} 360w, #{valid} 360w" ].each do |candidate|
      assert_raises(Railpress::ThemeRenderer::Invalid) { Railpress::ThemeRenderer.guard!(%(<picture><source type="image/webp" srcset="#{candidate}"></picture>), bundle: bundle) }
    end
    assert_raises(Railpress::ThemeRenderer::Invalid) { Railpress::ThemeRenderer.guard!(%(<source type="image/webp" srcset="#{valid} 360w">), bundle: bundle) }
    assert_raises(Railpress::ThemeRenderer::Invalid) { Railpress::ThemeRenderer.guard!(%(<picture><source type="image/svg+xml" srcset="#{valid} 360w"></picture>), bundle: bundle) }
    assert_raises(Railpress::ThemeRenderer::Invalid) { Railpress::ThemeRenderer.guard!(%(<picture><source type="image/webp" srcset="#{valid} 360w" sizes="url(https://attacker.invalid)"></picture>), bundle: bundle) }
  end
  test "WebP rejects animation trailing data wrong dimensions and corrupt compressed pixels" do
    bytes = File.binread(Rails.root.join("themes/dusk/assets/art-hero-360.webp"))
    assert_equal 360, Railpress::ThemeWebp.validate!(bytes)[:width]
    oversized = bytes.dup
    oversized[26, 2] = [ 1025 ].pack("v")
    extended = bytes.dup
    extended[12, 4] = "VP8X"
    [ bytes[0...-1], bytes + "<script>", oversized, extended ].each do |bad|
      assert_raises(Railpress::ThemeWebp::Invalid) { Railpress::ThemeWebp.validate!(bad) }
    end
    # Keep a canonical container and frame header, but remove the coded image.
    corrupt = bytes.byteslice(0, 30)
    corrupt[4, 4] = [ 22 ].pack("V")
    corrupt[16, 4] = [ 10 ].pack("V")
    assert Railpress::ThemeWebp.inspect!(corrupt)
    assert_raises(Railpress::ThemeWebp::Invalid) { Railpress::ThemeWebp.validate!(corrupt) }
    assert_raises(Railpress::ImageInput::Invalid) { Railpress::ImageInput.inspect!(bytes) }
  end
  test "missing native decoder refuses new package and preserves the current ordinary theme" do
    previous = ENV["RAILPRESS_WEBP_DECODER"]
    prior = stage
    activate(prior)
    directory = File.join(@private_root, "missing-decoder")
    Railpress::DuskPackage.build(directory, root: Rails.root, signer: @signer)
    ENV.delete("RAILPRESS_WEBP_DECODER")
    assert_raises(Railpress::ThemePackage::Invalid) { Themes::Manager.stage!(actor: @owner, directory: directory) }
    assert_equal prior.id, ThemeState.first.active_installation_id
    get "/"
    assert_response :ok
  ensure
    ENV["RAILPRESS_WEBP_DECODER"] = previous
  end
  test "artwork values remain Owner authorized and immutable recovery retains the exact option" do
    package = artwork_package
    original = Themes::Storage.load(package).files
    [ nil, "", "auto", "<script>", [ "editorial" ] ].each do |value|
      assert_raises(ArgumentError) { Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { artwork_style: value }) }
    end
    none = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { artwork_style: "none" })
    activate(package, none)
    other = stage
    activate(other)
    Themes::Manager.revert!(actor: @owner, version: ThemeState.first.lock_version)
    assert_equal none.id, ThemeState.first.active_overlay_id
    assert_equal "none", ThemeState.first.active_overlay.options["artwork_style"]
    assert_equal original, Themes::Storage.load(package).files
    assert_raises(Identity::Capabilities::Denied) { Themes::Manager.overlay!(actor: @editor, installation: package, attributes: { artwork_style: "editorial" }) }
  end
  test "decoder wall deadline terminates its exact child without weakening limits" do
    bytes = File.binread(Rails.root.join("themes/dusk/assets/art-hero-360.webp"))
    utility = File.join(@private_root, "slow-dwebp")
    marker = File.join(@private_root, "decoder-pid")
    File.write(utility, "#!#{RbConfig.ruby}\nif ARGV == ['-version']\n puts '1.6.0'\nelse\n File.write(#{marker.inspect}, Process.pid.to_s)\n sleep 30\nend\n", perm: 0o700)
    previous = ENV["RAILPRESS_WEBP_DECODER"]
    ENV["RAILPRESS_WEBP_DECODER"] = utility
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Railpress::ThemeWebp::Invalid) { Railpress::ThemeWebp.validate!(bytes) }
    assert_equal "webp_decode_timeout", error.message
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :>=, 4.5
    assert_operator elapsed, :<, 6
    pid = Integer(File.read(marker))
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    evidence("artwork-decoder-deadline", elapsed_seconds: elapsed, child_reaped: true, original_wall_limit: 5)
  ensure
    ENV["RAILPRESS_WEBP_DECODER"] = previous
  end
  test "missing active bundled image fails safely and leaves protected recovery available" do
    prior = stage
    activate(prior)
    package = artwork_package
    activate(package)
    get "/"
    assert_response :ok
    directory = Themes::Storage.path(package.theme_key, package.version, package.digest)
    asset_directory = File.join(directory, "assets")
    File.chmod(0o700, asset_directory)
    File.unlink(File.join(asset_directory, "art-hero-360.webp"))
    get "/"
    assert_response :service_unavailable
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_select 'link[rel="canonical"]', count: 0
    assert_equal package.id, ThemeState.first.active_installation_id
    sign_in
    get "/admin/themes"
    assert_response :ok
    Themes::Manager.revert!(actor: @owner, version: ThemeState.first.lock_version)
    get "/"
    assert_response :ok
    assert_equal prior.id, ThemeState.first.active_installation_id
  end
  test "membership auth namespace preserves previously valid public members page URLs" do
    package = artwork_package
    activate(package)
    page = change(draft("Page", slug: "members/login"), "publish")
    get "/members/login"
    assert_response :ok
    assert_select 'link[rel="canonical"][href="https://publishing.example.invalid/members/login"]'
    assert_equal "/members/login", Seo::RouteRegistry.content_path(page, site)
    get "/login/members/login"
    assert_response :ok
    assert_select 'link[rel="canonical"]', count: 0
    assert_equal "no-store", response.headers["Cache-Control"]
    get "/login/members/account"
    assert_redirected_to "/login/members/login"
  end
end
