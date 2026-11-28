# frozen_string_literal: true

require "test_helper"
require_relative "../support/theme_test_support"
require_relative "../support/theme_upload_test_support"
require_relative "../support/administration_test_support"
require_relative "../support/extension_test_support"

class ThemeUploadTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  include ThemeUploadTestSupport
  include AdministrationTestSupport
  include ExtensionTestSupport

  setup { configure_zip_publisher }
  teardown { cleanup_extension_site }

  test "upload preview publish update and revert preserve immutable assets and mapped overlays" do
    dusk = stage("dusk")
    activate(dusk)
    sign_in
    get "/admin/themes"
    assert_response :ok
    assert_select "form[action='/admin/themes/uploads'] input[type='file']"
    assert_select "section p", text: /Upload a ZIP from an approved publisher/
    old = upload_and_validate(theme_zip).theme_installation
    overlay = Themes::Manager.overlay!(actor: @owner, installation: old, attributes: { palette: "stone", footer: "Retained synthetic footer" })
    assert_equal dusk.id, ThemeState.sole.active_installation_id
    publish(old, overlay)
    assert_response :conflict

    select_preview(old, overlay)
    get "/"
    assert_response :ok
    assert_includes response.body, "Retained synthetic footer"
    assert_includes response.headers["Cache-Control"], "no-store"
    private_asset = asset_url(old, preview: true)
    assert_includes response.body, private_asset
    get private_asset
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_includes response.headers["X-Robots-Tag"], "noindex"

    other = open_session
    other.https!
    other.get private_asset
    assert_equal 404, other.response.status
    other.get asset_url(old)
    assert_equal 404, other.response.status
    sign_in(other)
    other.get private_asset
    assert_equal 404, other.response.status
    other.post "/admin/themes/#{old.id}/activate", params: { overlay_id: overlay.id, version: ThemeState.sole.lock_version,
      authenticity_token: csrf_token_for(other, "/admin/themes") }
    assert_equal 409, other.response.status

    publish(old, overlay)
    assert_response :see_other
    get asset_url(old)
    assert_response :ok
    assert_includes response.headers["Cache-Control"], "immutable"
    original_css = response.body
    get private_asset
    assert_response :not_found

    update = upload_and_validate(theme_zip(version: "1.1.0", schema: 2, mutate: ->(manifest, _) {
      manifest["options"]["palettes"] = [ "ocean" ]
    }))
    recent = update.theme_installation
    inherited = recent.theme_overlays.sole
    assert_equal "Retained synthetic footer", inherited.options["footer"]
    assert_equal "ocean", inherited.options["palette"]
    assert_equal [ "palette" ], update.overlay_mapping["reset"]
    assert_equal old.id, ThemeState.sole.active_installation_id
    select_preview(recent, inherited)
    publish(recent, inherited)
    assert_response :see_other
    assert_equal recent.id, ThemeState.sole.active_installation_id
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/revert", params: { version: ThemeState.sole.lock_version, authenticity_token: csrf }
    assert_response :see_other
    assert_equal overlay.id, ThemeState.sole.active_overlay_id
    get asset_url(old)
    assert_equal original_css, response.body
    get asset_url(recent)
    assert_response :ok
    select_preview(dusk, dusk.theme_overlays.first)
    publish(dusk, dusk.theme_overlays.first)
    assert_response :see_other
    assert_equal dusk.id, ThemeState.sole.active_installation_id
  end

  test "unsigned publisher scope CSRF and private root failures preserve the selected package" do
    dusk = stage("dusk")
    activate(dusk)
    path = theme_zip
    admin = create_account("administrator")
    sign_in(self, admin)
    post "/admin/themes/uploads", params: { theme_zip: http_file(path), authenticity_token: csrf_token_for(self, "/admin") }
    assert_response :forbidden
    sign_in
    post "/admin/themes/uploads", params: { theme_zip: http_file(path) }
    assert_response :unprocessable_entity
    assert_empty ThemeUpload.all

    root = Themes::UploadStorage.root
    File.chmod(0o755, root)
    begin
      submit_zip(path)
      assert_response :service_unavailable
    ensure
      File.chmod(0o700, root)
    end
    with_method(Railpress::Releases::Filesystem, :capacity!, ->(*) { raise Railpress::Releases::Invalid, "disk_capacity" }) do
      submit_zip(path)
      assert_response :service_unavailable
    end
    assert_empty ThemeUpload.all

    configure_zip_publisher(scope: [ "unrelated" ])
    with_method(Themes::Smoke, :call, ->(*) { flunk "Unscoped package reached executable smoke" }) do
      perform_enqueued_jobs(only: ValidateThemeUploadJob) { submit_zip(path) }
    end
    assert_response :see_other
    assert_equal [ "rejected", "upload_publisher_scope" ], ThemeUpload.sole.attributes.values_at("state", "result_code")
    assert_equal dusk.id, ThemeState.sole.active_installation_id
    get "/upload-quarantine/#{ThemeUpload.sole.operation_key}.zip"
    assert_response :not_found
  end

  test "immutable rename before SQL failure remains private and a retry reconciles exact bytes" do
    dusk = stage("dusk")
    activate(dusk)
    sign_in
    original = Activity::Recorder.method(:record!)
    reject_stage = lambda do |**arguments|
      raise Activity::Recorder::Unavailable, "synthetic SQL refusal" if arguments[:action] == "theme.stage"
      original.call(**arguments)
    end
    with_method(Activity::Recorder, :record!, reject_stage) do
      perform_enqueued_jobs(only: ValidateThemeUploadJob) { submit_zip(theme_zip) }
    end
    upload = ThemeUpload.sole
    assert_equal "held", upload.state
    assert_nil upload.theme_installation_id
    assert_equal dusk.id, ThemeState.sole.active_installation_id
    assert_equal [ "dusk" ], ThemeInstallation.pluck(:theme_key)
    digest = upload.manifest_sha256
    assert File.directory?(Themes::Storage.path("harbor", "1.0.0", digest))
    get "/theme-assets/harbor/1.0.0/#{digest}/public.css"
    assert_response :not_found

    csrf = csrf_token_for(self, "/admin/themes")
    perform_enqueued_jobs(only: ValidateThemeUploadJob) do
      post "/admin/themes/uploads/#{upload.id}/resume", params: { authenticity_token: csrf }
    end
    assert_response :see_other
    assert_equal "staged", upload.reload.state
    assert_equal digest, upload.theme_installation.digest
    assert_equal dusk.id, ThemeState.sole.active_installation_id
  end

  test "capability-dependent schema 2 theme publishes only with the selected enabled module and renders its typed slot" do
    dusk = stage("dusk")
    activate(dusk)
    sign_in
    package = upload_and_validate(theme_zip(schema: 2, required: true)).theme_installation
    select_preview(package, package.theme_overlays.sole)
    publish(package, package.theme_overlays.sole)
    assert_response :conflict
    assert_equal dusk.id, ThemeState.sole.active_installation_id
    prepare_neutral_presentation
    current = @presentation_registry
    with_method(Ext, :registry, current) do
      get "/theme-preview-assets/#{package.theme_key}/#{package.version}/#{package.digest}/public.css"
      assert_response :not_found
      select_preview(package, package.theme_overlays.sole)
      publish(package, package.theme_overlays.sole)
      assert_response :see_other
      assert_equal package.id, ThemeState.sole.active_installation_id
    end
    live = process_probe(<<~RUBY)
      begin
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.https!
        client.get("/extensions/neutral-probe/presentation")
        [client.response.status, client.response.body.include?("qualified-slot"),
          client.response.body.include?("Neutral entry"), client.response.headers["X-Robots-Tag"]]
      end
    RUBY
    assert_equal [ 200, true, true, "noindex, nofollow" ], live.fetch("probe")
    change_activation(current, false, 1)
    assert_equal 404, process_probe(<<~RUBY).fetch("probe")
      begin
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.https!
        client.get("/extensions/neutral-probe/presentation")
        client.response.status
      end
    RUBY
    get "/"
    assert_response :ok
    assert_equal package.id, ThemeState.sole.active_installation_id
    select_preview(dusk, dusk.theme_overlays.first)
    publish(dusk, dusk.theme_overlays.first)
    assert_response :see_other
  end

  private

  def submit_zip(path)
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/uploads", params: { theme_zip: http_file(path), authenticity_token: csrf }
  end

  def upload_and_validate(path)
    perform_enqueued_jobs(only: ValidateThemeUploadJob) { submit_zip(path) }
    assert_response :see_other
    upload = ThemeUpload.order(:id).last
    assert_equal "staged", upload.state, upload.result_code
    upload
  end

  def http_file(path) = Rack::Test::UploadedFile.new(path, "application/zip")

  def asset_url(package, preview: false)
    prefix = preview ? "theme-preview-assets" : "theme-assets"
    "/#{prefix}/#{package.theme_key}/#{package.version}/#{package.digest}/public.css"
  end

  def select_preview(package, overlay)
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/#{package.id}/preview", params: { overlay_id: overlay.id, authenticity_token: csrf }
    assert_response :see_other
  end

  def publish(package, overlay)
    csrf = csrf_token_for(self, "/admin/themes")
    post "/admin/themes/#{package.id}/activate", params: { overlay_id: overlay.id, version: ThemeState.sole.lock_version, authenticity_token: csrf }
  end

  def prepare_neutral_presentation
    @extension_config = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
    Railpress::TestDatabase.verify!(@extension_config)
    @extension_site = Site.sole
    @extension_root = File.join(@private_root, "engine-store")
    Dir.mkdir(@extension_root, 0o700)
    @publisher_key = OpenSSL::PKey.generate_key("ED25519")
    @operator_key = OpenSSL::PKey.generate_key("ED25519")
    write_extension_trust
    row, = stage_package(version: "1.0.0", migration_count: 0, manifest_changes: { "slots" => [ "neutral-probe.public_profile" ] })
    @presentation_registry = load_extension_set([ row ])
    entry = @presentation_registry.entries.fetch(MODULE_ID)
    ExtensionInstallation.create!(site: @extension_site, module_id: MODULE_ID, version: entry.version,
      package_sha256: entry.package_sha256, manifest_sha256: entry.manifest.digest, package_state: "installed",
      enabled: true, activation_generation: 1, engine_generation: @presentation_registry.generation,
      engine_fingerprint: @presentation_registry.fingerprint, module_schema: 0, job_revision: 0)
  end
end
