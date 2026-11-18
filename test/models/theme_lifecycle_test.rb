require "test_helper"
require_relative "../support/theme_test_support"
class ThemeLifecycleTest < ActiveSupport::TestCase
  include ThemeTestSupport
  test "optimistic concurrent activations yield exactly one winner and retain prior pair" do
    dusk = stage("dusk"); activate(dusk)
    harbor = stage
    alternate = Themes::Manager.overlay!(actor: @owner, installation: harbor, attributes: { footer: "Alternate" })
    prepare_preview(harbor)
    prepare_preview(harbor, alternate)
    version = ThemeState.first.lock_version
    results = parallel_results(2) do |index|
      begin
        Themes::Manager.activate!(actor: User.find(@owner.id), installation: ThemeInstallation.find(harbor.id), overlay: ThemeOverlay.find(index.zero? ? harbor.theme_overlays.first.id : alternate.id), version: version)
        "activated"
      rescue Themes::Manager::Conflict
        "conflict"
      end
    end
    assert_equal %w[activated conflict], results.sort
    state = ThemeState.first.reload
    assert_equal harbor.id, state.active_installation_id
    assert_equal dusk.id, state.previous_installation_id
    assert_equal version + 1, state.lock_version
    assert_includes [ harbor.theme_overlays.first.id, alternate.id ], state.active_overlay_id
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-theme-concurrency.json"), JSON.pretty_generate(results: results, state_version: state.lock_version, active: state.active_installation.public_identity, previous: state.previous_installation.public_identity) + "\n")
  end
  test "default active previous and preview leased packages refuse removal then compatible revert works" do
    dusk = stage("dusk"); harbor = stage; spare = stage("harbor", version: "1.1.0")
    activate(dusk); activate(harbor)
    [ dusk, harbor ].each { |package| assert_raises(Themes::Manager::Protected) { Themes::Manager.remove!(actor: @owner, installation: package) } }
    Themes::Manager.revert!(actor: @owner, version: ThemeState.first.lock_version)
    assert_equal dusk.id, ThemeState.first.active_installation_id
    assert_equal harbor.id, ThemeState.first.previous_installation_id
    authentication = UserSession.issue!(@owner)
    Themes::Manager.preview!(actor: @owner, installation: spare, overlay: spare.theme_overlays.first, authentication_token: authentication)
    assert_raises(Themes::Manager::Protected) { Themes::Manager.remove!(actor: @owner, installation: spare) }
    ThemePreview.update_all(expires_at: 1.minute.ago)
    Themes::Manager.remove!(actor: @owner, installation: spare)
    assert_equal "removed", spare.reload.status
    assert File.directory?(Themes::Storage.path(spare.theme_key, spare.version, spare.digest)), "immutable bytes retained pending qualified operator GC"
    assert_raises(Railpress::ThemePackage::Invalid) { activate(spare) }
  end
  test "typed overlays append history retain media and reject unauthorized unknown and invalid fields" do
    package = stage
    original = package.theme_overlays.first
    asset = upload_media(actor: @owner)
    customized = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { palette: "stone", font: "system_serif", layout: "wide", home_pattern: "feature", footer: "Independent footer", logo_id: asset.id, favicon_id: asset.id })
    assert_equal 2, customized.number
    assert_equal "Independent footer", customized.options["footer"]
    assert_equal 1, MediaReference.where(theme_overlay: customized).count
    assert_equal "A synthetic blue studio", customized.media_details.dig("logo", "alt")
    assert_raises(MediaLibrary::Manage::InUse) { MediaLibrary::Manage.purge!(actor: @owner, asset: asset) }
    assert_raises(ActiveRecord::RecordNotSaved) { original.update!(options: { "footer" => "vendor edit" }) }
    [ { palette: "#ffffff" }, { font: "external_font" }, { footer: "<script>bad</script>" }, { template_path: "/etc/passwd" } ].each do |attributes|
      assert_raises(ArgumentError) { Themes::Manager.overlay!(actor: @owner, installation: package, attributes: attributes) }
    end
    assert_raises(Identity::Capabilities::Denied) { Themes::Manager.overlay!(actor: @editor, installation: package, attributes: {}) }
    assert_equal 2, package.theme_overlays.count
    assert_equal "", original.reload.options["footer"]
  end
  test "preview token is owner authentication version session and expiry bound" do
    package = stage
    authentication = UserSession.issue!(@owner)
    credential = Themes::Manager.preview!(actor: @owner, installation: package, overlay: package.theme_overlays.first, authentication_token: authentication)
    assert Themes::Selection.preview(@owner, authentication, credential)
    assert_nil Themes::Selection.preview(@owner, UserSession.issue!(@owner), credential)
    assert_nil Themes::Selection.preview(@editor, authentication, credential)
    assert_nil Themes::Selection.preview(@owner, authentication, { "token" => "0" * 64 })
    @owner.update_columns(auth_version: @owner.auth_version + 1)
    assert_nil Themes::Selection.preview(@owner.reload, authentication, credential)
    @owner.update_columns(auth_version: @owner.auth_version - 1)
    ThemePreview.update_all(expires_at: 1.minute.ago)
    assert_nil Themes::Selection.preview(@owner, authentication, credential)
  end
  test "installed paths are write once and symlink parent escapes fail" do
    package = stage
    path = Themes::Storage.path(package.theme_key, package.version, package.digest)
    assert_equal 0, File.stat(File.join(path, "templates/post.html.erb")).mode & 0o222
    assert_equal 0, File.stat(path).mode & 0o222
    digest = package.digest
    assert_equal digest, Themes::Storage.load(package).digest
    FileUtils.mkdir_p(File.join(Themes::Storage.root, "outside"))
    File.symlink(File.join(Themes::Storage.root, "outside"), File.join(Themes::Storage.root, "packages", "escape"))
    assert_raises(Railpress::ThemePackage::Invalid) { Themes::Storage.path("escape", "1.0.0", "0" * 64) }
    previous = ENV["RAILPRESS_THEME_ROOT"]
    with_method(Rails, :env, -> { ActiveSupport::StringInquirer.new("production") }) do
      [ Rails.root.to_s, previous ].each do |inside|
        ENV["RAILPRESS_THEME_ROOT"] = inside
        error = assert_raises(Railpress::ThemePackage::Invalid) { Themes::Storage.root }
        assert_equal "theme_root_inside_release", error.message
      end
      ENV.delete("RAILPRESS_THEME_ROOT")
      error = assert_raises(Railpress::ThemePackage::Invalid) { Themes::Storage.root }
      assert_equal "persistent_theme_root_required", error.message
    end
  ensure
    ENV["RAILPRESS_THEME_ROOT"] = previous if previous
  end
end
