require "test_helper"
require_relative "../support/installation_test_support"
require_relative "../support/gcs_api_fixture"
require "active_storage/service/railpress_gcs_service"

class InstallationStorageTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport
  def replacing(receiver, name, implementation)
    original = receiver.method(name)
    receiver.define_singleton_method(name, implementation)
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end
  def begin_storage
    prepare_install_schema
    claim = @state.claim!(@state.issue!)
    wizard = Installation::Wizard.new(@state)
    wizard.start!(claim)
    %w[environment database].each { |step| wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: step, fields: install_fields(step)) }
    [ claim, wizard ]
  end
  def gcs_fields(source = "federation", method = "adc")
    { "backend" => "gcs", "project" => "synthetic-project", "bucket" => "synthetic-private-media", "prefix" => "r8/media", "identity_source" => source, "auth_method" => method, "storage_limits_ack" => "1" }
  end
  def with_gcs(source: "federation", method: "adc", credentials: true)
    saved = ActiveStorage::Blob.service
    registered = ActiveStorage::Blob.services.instance_variable_get(:@services)[:gcs]
    keys = %w[HOME GOOGLE_APPLICATION_CREDENTIALS CLOUDSDK_CONFIG RAILPRESS_GCS_CREDENTIALS_FILE RAILPRESS_QUARANTINE_ROOT]
    before = keys.to_h { |key| [ key, ENV[key] ] }
    Dir.mktmpdir("railpress-r8-storage-credentials-", "/dev/shm") do |dir|
      ENV["HOME"] = dir
      ENV["GOOGLE_APPLICATION_CREDENTIALS"] = nil
      ENV["RAILPRESS_GCS_CREDENTIALS_FILE"] = nil
      ENV["CLOUDSDK_CONFIG"] = dir
      if credentials
        path = File.join(dir, "identity.json")
        File.write(path, JSON.generate("type" => method == "adc" ? "external_account" : "service_account", "credential_source" => { "file" => "/synthetic-subject-token-not-opened" }), perm: 0o600)
        ENV[method == "adc" ? "GOOGLE_APPLICATION_CREDENTIALS" : "RAILPRESS_GCS_CREDENTIALS_FILE"] = path
      end
      ENV["RAILPRESS_QUARANTINE_ROOT"] = File.join(@private_root, "processing")
      FileUtils.mkdir_p(ENV["RAILPRESS_QUARANTINE_ROOT"], mode: 0o700)
      @api = GcsApiFixture.new
      @gcs = ActiveStorage::Service::RailpressGcsService.new(bucket: "synthetic-private-media", project: "synthetic-project", prefix: "r8/media", auth_method: method, identity_source: source)
      @gcs.name = :gcs
      @gcs.instance_variable_set(:@store, Railpress::Gcs::Store.new(bucket: "synthetic-private-media", project: "synthetic-project", prefix: "r8/media", auth_method: method, identity_source: source, client: @api))
      ActiveStorage::Blob.services.instance_variable_get(:@services)[:gcs] = @gcs
      ActiveStorage::Blob.service = @gcs
      replacing(Google::Auth, :get_application_default, ->(*) { flunk "installer must not contact ADC" }) { yield }
    end
  ensure
    ActiveStorage::Blob.service = saved if saved
    registry = ActiveStorage::Blob.services.instance_variable_get(:@services)
    registered ? registry[:gcs] = registered : registry.delete(:gcs)
    before&.each { |key, value| ENV[key] = value }
  end
  def finish_storage_install(claim, wizard, chosen)
    wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: "storage", fields: chosen)
    assert_equal "identity", wizard.progress.read["step"]
    %w[identity owner appearance membership].each { |step| wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: step, fields: install_fields(step)) }
    Installation::Finish.call(state: @state, claim: claim, revision: wizard.progress.read["revision"])
  end
  test "claimed form recommends GCS ADC offers functional Disk and never requests cloud credentials" do
    prepare_install_schema
    csrf = csrf_token_for(self, "/setup")
    post "/setup/claim", params: { authenticity_token: csrf, setup_secret: @state.issue! }
    %w[environment database].each { |step| advance_install(self, step) }
    get "/setup"
    assert_select 'input[name="fields[backend]"][value="gcs"][checked]'
    assert_select 'select[name="fields[auth_method]"] option[value="adc"][selected]'
    assert_select 'input[name="fields[backend]"][value="local"]'
    assert_select 'input[type="password"]', count: 0
    assert_includes response.body, "recommended for production"
    assert_includes response.body, "NOT TESTED"
    assert_select 'a[href="/setup/storage-guide"]'
    get "/setup/storage-guide"
    assert_response :ok
    assert_includes response.body, "outside source and Git"
  end
  test "unclaimed mutation cannot inspect credentials contact providers or save storage intent" do
    @state.issue!
    token = csrf_token_for(self, "/setup")
    replacing(MediaLibrary::Configuration, :observe, ->(*) { flunk "unclaimed probe" }) do
      post "/setup/steps/storage", params: { authenticity_token: token, revision: 0, fields: gcs_fields }
    end
    assert_response :forbidden
    refute Installation::Progress.new(@state).read.dig("data", "storage")
    assert_nil MediaLibrary::Configuration.intent
  end
  test "different host configuration saves intent and survives interruption without probing arbitrary endpoints" do
    claim, wizard = begin_storage
    fields = gcs_fields.merge("credentials" => "PRIVATE-CANARY", "endpoint" => "http://169.254.169.254")
    replacing(Google::Auth, :get_application_default, ->(*) { flunk "no ADC probe during handoff" }) do
      value = wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: "storage", fields: fields)
      assert_equal "storage", value["step"]
      assert_equal %w[environment database], value["completed"]
      assert_equal "gcs", value.dig("data", "storage", "backend")
      assert_equal value, Installation::Progress.new(Railpress::BootstrapState.new(@private_root)).read
      text = File.read(File.join(@private_root, "installation.json"))
      refute_includes text, "PRIVATE-CANARY"
      refute_includes text, "169.254"
    end
    stale = wizard.progress.read["revision"] - 1
    assert_raises(Installation::Progress::Conflict) { wizard.advance!(claim: claim, revision: stale, step: "storage", fields: fields) }
    assert_equal 0, User.count
  end
  test "invalid typed identifiers never produce a provider request or approved intent" do
    claim, wizard = begin_storage
    [ { "project" => "http://localhost" }, { "bucket" => "169.254.169.254" }, { "prefix" => "../outside" }, { "auth_method" => "credentials-from-browser" } ].each do |bad|
      assert_raises(Railpress::MediaConfiguration::Invalid) { wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: "storage", fields: gcs_fields.merge(bad)) }
    end
    assert_nil wizard.progress.read.dig("data", "storage")
  end
  test "federation selection finishes ordinary installer retains private media and closes setup" do
    with_gcs do
      claim, wizard = begin_storage
      owner = finish_storage_install(claim, wizard, gcs_fields)
      assert @state.installed?
      assert_equal "gcs", MediaLibrary::Configuration.intent["backend"]
      assert_equal "federation", MediaLibrary::Configuration.intent["identity_source"]
      assert_empty @api.calls
      report = MediaLibrary::Configuration.observe(MediaLibrary::Configuration.intent)
      assert_equal "CONFIGURED", report["state"]
      assert_equal "NOT TESTED", report["cells"].find { |c| c["key"] == "provider" }["state"]
      assert_equal "NOT TESTED", MediaLibrary::Configuration.agreement["state"]
      png = Vips::Image.black(32, 24).new_from_image([ 20, 70, 90 ]).pngsave_buffer
      asset = MediaLibrary::Upload.call(actor: owner, io: StringIO.new(png), filename: "synthetic.png", content_type: "image/png", attributes: { "alt_text" => "Original synthetic pixels", "license_notes" => "Original synthetic pixels" })
      assert_equal "r8/media", asset.blob.metadata["railpress_gcs"]["prefix"]
      assert_equal asset.sha256, Digest::SHA256.hexdigest(MediaLibrary::Delivery.read(asset, "display"))
      before = @api.fingerprint
      MediaLibrary::Manage.purge!(actor: owner, asset: asset)
      assert_equal before, @api.fingerprint
      assert_equal "VERIFIED", @gcs.store.verify(asset.reload.retained_objects.first)
      get "/setup"
      assert_response :gone
    end
  end
  test "attached identity and explicit fallback configure locally without claiming token or provider success" do
    with_gcs(source: "attached", credentials: false) do
      claim, wizard = begin_storage
      owner = finish_storage_install(claim, wizard, gcs_fields("attached"))
      assert owner.owner?
      assert @state.installed?
      assert_empty @api.calls
    end
  end
  test "explicit operator fallback is accepted only when selected on both host and installer" do
    with_gcs(source: "native", method: "service_account_file") do
      claim, wizard = begin_storage
      owner = finish_storage_install(claim, wizard, gcs_fields("native", "service_account_file"))
      value = wizard.progress.read
      assert owner.owner?
      assert @state.installed?
      refute_includes JSON.generate(value), ENV["RAILPRESS_GCS_CREDENTIALS_FILE"]
      assert_empty @api.calls
    end
  end
  test "default automatic ADC source completes with visible external account config and no live provider claim" do
    with_gcs(source: "automatic") do
      claim, wizard = begin_storage
      owner = finish_storage_install(claim, wizard, gcs_fields("automatic"))
      assert owner.owner?
      assert @state.installed?
      assert_equal "adc", MediaLibrary::Configuration.intent["auth_method"]
      assert_equal "NOT TESTED", MediaLibrary::Configuration.agreement["state"]
      assert_empty @api.calls
    end
  end
  test "missing selected ADC saves pending choice and recovers safely after operator prerequisites" do
    with_gcs(credentials: false) do
      claim, wizard = begin_storage
      value = wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: "storage", fields: gcs_fields)
      assert_equal "storage", value["step"]
      assert_equal "ACTION REQUIRED", MediaLibrary::Configuration.observe(value.dig("data", "storage"))["state"]
      assert_empty @api.calls
    end
  end
  test "environment drift after review refuses completion instead of switching an existing library" do
    claim, wizard = begin_storage
    wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: "storage", fields: install_fields("storage"))
    %w[identity owner appearance membership].each { |step| wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: step, fields: install_fields(step)) }
    active = MediaLibrary::Configuration.runtime.merge("disk_root" => "/different/operator/path")
    replacing(MediaLibrary::Configuration, :runtime, -> { active }) do
      assert_raises(MediaLibrary::Configuration::Handoff) { Installation::Finish.call(state: @state, claim: claim, revision: wizard.progress.read["revision"]) }
    end
    assert_equal 0, Site.count
    assert_equal 0, User.count
  end
end
