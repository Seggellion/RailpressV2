# frozen_string_literal: true

require "test_helper"
require "railpress/native_host"
require_relative "../support/extension_test_support"
require_relative "../support/administration_test_support"

class ModuleCatalogTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include ExtensionTestSupport
  include AdministrationTestSupport

  CATALOG = "railpress-test"
  REVIEW = "/admin/modules/add?module=neutral-probe&catalog=#{CATALOG}"

  setup do
    prepare_extension_site
    https!
    host! URI(@extension_site.canonical_origin).authority
    @package, @package_path = stage_package(version: "1.0.0")
    @registry = load_extension_set([])
    @catalog_key = OpenSSL::PKey.generate_key("ED25519")
    @catalog_path = File.join(@extension_root, "catalogs", CATALOG)
    FileUtils.mkdir_p(@catalog_path)
    stage_catalog
  end
  teardown { cleanup_extension_site }

  test "GET and HEAD hold no install authority and local Owner POST converges and can cancel before verification" do
    admitted do
      head REVIEW
      assert_response :see_other
      get REVIEW + "&return_to=https://example.invalid"
      assert_redirected_to login_url
      assert_empty ExtensionInstallRequest.all
      sign_in
      assert_redirected_to admin_module_catalog_path(catalog: CATALOG, module: MODULE_ID)
      proof, csrf = confirmation
      assert_empty ExtensionInstallRequest.all
      post "/admin/modules/add", params: { confirmation: proof }
      assert_response :unprocessable_entity
      post "/admin/modules/add", params: { confirmation: proof, authenticity_token: csrf }
      assert_response :see_other
      request = ExtensionInstallRequest.sole
      assert_equal @package.values_at("version", "manifest_sha256", "package_sha256"),
        request.attributes.values_at("version", "manifest_sha256", "package_sha256")
      assert_empty ExtensionInstallation.all
      location = response.location
      post "/admin/modules/add", params: { confirmation: proof, authenticity_token: csrf }
      assert_equal location, response.location
      assert_equal request.id, ExtensionInstallRequest.sole.id
      token = csrf_token_for(self, location)
      post "/admin/modules/requests/#{request.request_key}/cancel", params: { authenticity_token: token }
      assert_response :see_other
      assert_equal "cancelled", request.reload.state
      event = ActivityEvent.where(action: "extension.cancelled").sole
      assert_equal request.package_sha256, event.details["digest"]
      assert_empty ExtensionInstallation.all
    end
  end

  test "confirmation is local to the original session, canonical origin and reviewed engine generation" do
    admitted do
      sign_in
      proof, csrf = confirmation
      second = open_session
      second.https!
      second.host! URI(@extension_site.canonical_origin).authority
      sign_in(second)
      foreign_csrf = csrf_token_for(second, REVIEW)
      second.post "/admin/modules/add", params: { confirmation: proof, authenticity_token: foreign_csrf }
      assert_equal 409, second.response.status
      host! "other.example.invalid"
      get REVIEW
      assert_response :conflict
      host! URI(@extension_site.canonical_origin).authority
      @registry = load_extension_set([], previous: @registry)
      post "/admin/modules/add", params: { confirmation: proof, authenticity_token: csrf }
      assert_response :conflict
      assert_empty ExtensionInstallRequest.all
    end
  end

  test "exact digest, expiry, revoked purpose, pin and compatibility are checked again at submission" do
    admitted do
      sign_in
      proof, csrf = confirmation
      stage_catalog(revoked: true)
      post "/admin/modules/add", params: { confirmation: proof, authenticity_token: csrf }
      assert_response :conflict
      get REVIEW
      assert_includes response.body, "publisher has been revoked"
      stage_catalog
      write_extension_trust(revoked: [ Crypto.key_id(@publisher_key) ])
      post "/admin/modules/add", params: { confirmation: proof, authenticity_token: csrf }
      assert_response :conflict
      write_extension_trust
      stage_catalog(expires: Time.now.to_i - 1)
      get REVIEW
      assert_includes response.body, "has expired"
      stage_catalog(core: { "min" => "3.0.0", "max_exclusive" => "4.0.0" })
      get REVIEW
      assert_includes response.body, "needs a compatible Core"
      stage_catalog(sequence: 1, pinned: 2)
      get REVIEW
      assert_includes response.body, "Catalog verification failed"
      stage_catalog(artifact: "https://example.invalid/archive")
      get REVIEW
      assert_includes response.body, "Catalog verification failed"
      stage_catalog
      file = File.join(@catalog_path, "catalog.json")
      changed = JSON.parse(File.binread(file))
      changed["statement"]["entries"][0]["name"] = "Changed after signing"
      write_json(file, changed)
      get REVIEW
      assert_includes response.body, "Catalog verification failed"
      stage_catalog(setup_path: "/admin/modules/other/manage")
      get REVIEW
      assert_includes response.body, "Catalog verification failed"
      stage_catalog
      File.unlink(File.join(@catalog_path, "catalog.json"))
      get REVIEW
      assert_includes response.body, "catalog is unavailable"
      assert_empty ExtensionInstallRequest.all
    end
  end

  test "the native operator rechecks the exact catalog after a request has been accepted" do
    admitted do
      sign_in
      proof, csrf = confirmation
      post "/admin/modules/add", params: { confirmation: proof, authenticity_token: csrf }
      operation = ExtensionInstallRequest.sole
      Extensions::CatalogHandoff.verify_operator_request!(operation, registry: @registry)
      stage_catalog(sequence: 2)
      error = assert_raises(Ext::Invalid) do
        Extensions::CatalogHandoff.verify_operator_request!(operation, registry: @registry)
      end
      assert_equal "module_catalog_review", error.message
      assert_equal "awaiting_operator", operation.reload.state
      assert_empty ExtensionInstallation.all
    end
  end

  test "catalog loss preserves the visible local installed state" do
    admitted do
      @registry = load_extension_set([ @package ], previous: @registry)
      ExtensionInstallation.create!(site: @extension_site, module_id: MODULE_ID, version: @package["version"],
        package_sha256: @package["package_sha256"], manifest_sha256: @package["manifest_sha256"], package_state: "installed",
        enabled: false, activation_generation: 1, engine_generation: @registry.generation, engine_fingerprint: @registry.fingerprint,
        module_schema: 1, job_revision: 1)
      File.unlink(File.join(@catalog_path, "catalog.json"))
      sign_in
      get REVIEW
      assert_response :ok
      assert_includes response.body, "Installed, disabled"
      assert_includes response.body, "catalog is unavailable"
      assert_nil Nokogiri::HTML(response.body).at_css('input[name="confirmation"]')
      assert_empty ExtensionInstallRequest.all
    end
  end

  test "ordinary administrators and unsupported operators never get an install confirmation" do
    administrator = open_session
    administrator.https!
    administrator.host! URI(@extension_site.canonical_origin).authority
    sign_in(administrator, create_account("administrator"))
    administrator.get REVIEW
    assert_equal 403, administrator.response.status
    sign_in
    get REVIEW
    assert_response :ok
    assert_includes response.body, "Set up a supported module operator"
    assert_nil Nokogiri::HTML(response.body).at_css('input[name="confirmation"]')
    assert_empty ExtensionInstallRequest.all
  end

  test "a signed verifying hold remains visible and cancellation does not cross the operator claim" do
    admitted do
      sign_in
      proof, csrf = confirmation
      post "/admin/modules/add", params: { confirmation: proof, authenticity_token: csrf }
      operation = ExtensionInstallRequest.sole
      accept(operation, @registry, "verifying", 1)
      show = "/admin/modules/requests/#{operation.request_key}"
      token = csrf_token_for(self, show)
      assert_includes response.body, "verifying the exact package"
      post "#{show}/cancel", params: { authenticity_token: token }
      assert_response :conflict
      accept(operation, @registry, "held", 2)
      get show
      assert_includes response.body, "Installation held"
      assert_empty ExtensionInstallation.all
    end
  end

  test "interrupted migration reconciles to a signed recovery hold without migration replay" do
    admitted do
      sign_in
      proof, csrf = confirmation
      post "/admin/modules/add", params: { confirmation: proof, authenticity_token: csrf }
      operation = ExtensionInstallRequest.sole
      accept(operation, @registry, "verifying", 1)
      accept(operation, @registry, "migrating", 2)
      path = @extension_root
      File.write(File.join(path, "extension-receipt.key"), @operator_key.private_to_pem, perm: 0o600)
      config = Object.new
      config.define_singleton_method(:path) { |name| File.join(path, name) }
      action = Railpress::NativeHost::ModuleOperation.allocate
      action.instance_variable_set(:@config, config)
      calls = []
      storage = Object.new
      storage.define_singleton_method(:persist) { |state| calls << [ :journal, state["recovery_required"] ] }
      runtime = Object.new
      runtime.define_singleton_method(:maintenance!) { |state, value| calls << [ :maintenance, value ]; state["maintenance"] = value }
      runtime.define_singleton_method(:stop_all_apps!) { |_state| calls << [ :stop ] }
      action.instance_variable_set(:@runtime, runtime)
      action.instance_variable_set(:@store, storage)
      action.define_singleton_method(:approval!) { |*| { "lock_sha256" => "a" * 64 } }
      state = { "maintenance" => false, "module_operation" => { "id" => operation.request_key, "lock" => "a" * 64, "phase" => "FENCED" } }
      result = action.send(:reconcile_interrupted!, state, operation.reload)
      assert_equal [ [ :journal, true ], [ :maintenance, true ], [ :stop ] ], calls
      assert_equal "RECOVERY_REQUIRED", state["module_operation"]["phase"]
      assert_equal [ operation.request_key, "recovery_required", false ], result.values_at("request_id", "state", "enabled")
      assert_equal 3, operation.reload.receipt_sequence
      assert_empty ExtensionInstallation.all
      get "/admin/modules/requests/#{operation.request_key}"
      assert_includes response.body, "Recovery required"
    end
  end

  private

  def admitted
    previous = ENV["RAILPRESS_NATIVE_PROFILE"]
    ENV["RAILPRESS_NATIVE_PROFILE"] = "isolated-synthetic-nginx-v1"
    with_method(Ext, :registry, -> { @registry }) { yield }
  ensure
    ENV["RAILPRESS_NATIVE_PROFILE"] = previous
  end

  def confirmation
    token = csrf_token_for(self, REVIEW)
    assert_response :ok
    proof = Nokogiri::HTML(response.body).at_css('input[name="confirmation"]')
    assert proof, Nokogiri::HTML(response.body).at_css("main").text
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    [ proof["value"], token ]
  end

  def stage_catalog(sequence: 1, pinned: sequence, revoked: false, expires: Time.now.to_i + 600, **changes)
    manifest = Ext::Manifest.new(File.binread(File.join(@package_path, "manifest.json")))
    entry = manifest.data.slice("id", "name", "version", "core", "extension_api", "license").merge(
      "summary" => "Review a synthetic module", "publisher" => "Synthetic publisher", "channel" => "stable",
      "manifest_sha256" => manifest.digest, "package_sha256" => @package["package_sha256"], "plan_sha256" => Ext.digest(manifest.migrations),
      "artifact" => "packages/#{MODULE_ID}/#{manifest.version}/#{@package['package_sha256']}/package.tar.gz",
      "setup_path" => "/admin/modules/#{MODULE_ID}/manage").merge(changes.stringify_keys)
    catalog = { "format" => Ext::Catalog::FORMAT, "id" => CATALOG, "sequence" => sequence, "issued_at" => Time.now.to_i - 2,
      "expires_at" => expires, "entries" => [ entry ] }
    key = Crypto.key_id(@catalog_key)
    write_json(File.join(@catalog_path, "catalog.json"), sign_extension(catalog, @catalog_key))
    write_json(File.join(@catalog_path, "pin.json"), { "id" => CATALOG, "sha256" => Ext.digest(catalog), "sequence" => pinned })
    write_json(File.join(@catalog_path, "trust.json"), { "format" => "railpress.extension-trust.v1", "revoked" => revoked ? [ key ] : [],
      "keys" => { key => { "public_key" => @catalog_key.public_to_pem, "purpose" => Ext::Catalog::FORMAT,
        "scopes" => [ CATALOG ], "minimum_sequence" => 1 } } })
  end
end
