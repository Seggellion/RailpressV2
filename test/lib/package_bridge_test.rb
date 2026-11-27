# frozen_string_literal: true

require "test_helper"
require "railpress/recovery"
require_relative "../support/release_test_support"

class PackageBridgeTest < ActiveSupport::TestCase
  include ReleaseTestSupport

  setup { release_setup }
  teardown { release_teardown }

  test "bridge metadata preserves the original reader fields and binds the runtime schema" do
    product = { "format" => "railpress.product.v1", "version" => "2.0.0-alpha.4", "channel" => "alpha",
      "security_clock" => 2, "theme_api" => 1, "extension_api" => 1, "schema" => 16, "jobs" => 1, "configuration" => 2 }
    path = "lib/railpress/product.json"
    files = { path => { "bytes" => JSON.generate(product), "mode" => 0o644 } }
    compatibility = { "schema_read" => [ 14, 16 ], "schema_write" => [ 14, 16 ] }
    bridge = Railpress::Releases::Builder.bridge_files(files, compatibility, 14)
    legacy = JSON.parse(bridge.fetch(path).fetch("bytes"))
    contract = JSON.parse(bridge.fetch("lib/railpress/product-package-contract.json").fetch("bytes"))
    assert_equal product.except("extension_api").merge("schema" => 14), legacy
    assert_equal product, Railpress::ProductMetadata.apply(legacy, contract)
    assert_raises(ArgumentError) { Railpress::ProductMetadata.apply(legacy, contract.merge("version" => "2.0.0-alpha.5")) }
    assert_refusal("product_bridge_schema") { Railpress::Releases::Builder.bridge_files(files, compatibility, 13) }
  end

  test "signed successor compatibility uses the private inventory without distributing its identities" do
    manifest = successor_manifest
    context = @release_context.merge("packages" => local_inventory)
    assert Railpress::Releases::Manifest.compatible!(manifest, context)
    refute_includes Railpress::Releases.canonical(manifest), "neutral-probe"
    assert_refusal("local_package_context_missing") { Railpress::Releases::Manifest.compatible!(manifest, @release_context) }

    context["packages"]["modules"].first["core"]["max_exclusive"] = manifest["version"]
    assert_refusal("module_core_window") { Railpress::Releases::Manifest.compatible!(manifest, context) }
    context["packages"]["modules"].first["core"]["max_exclusive"] = "3.0.0"
    context["packages"]["jobs"] = [ "ValidateThemeUploadJob" ]
    assert_refusal("module_job_reader") { Railpress::Releases::Manifest.compatible!(manifest, context) }
  end

  test "package-bearing source refuses an older reader and incorrect local package evidence" do
    local = local_inventory
    assert_refusal("package_reader_required") { Railpress::Releases::PackageContext.admit!(@release_fixture.fetch("manifest"), local) }

    manifest = successor_manifest
    local["themes"].first["digest"] = "a" * 64
    assert_refusal("bundled_dusk_identity") { Railpress::Releases::PackageContext.admit!(manifest, local) }
    local["themes"].first["digest"] = "d" * 64
    local["modules"].first["jobs"] = 4
    assert_refusal("module_data_window") { Railpress::Releases::PackageContext.admit!(manifest, local) }
  end

  test "Disk inventory rejects a replaced mount and writable or over-quota content" do
    Dir.mktmpdir("disk-guards-", @operator_root) do |parent|
      roots = Railpress::Recovery::Disk::ROOTS.to_h do |name|
        path = File.join(parent, name)
        Dir.mkdir(path, 0o700)
        [ name, path ]
      end
      store = Railpress::Recovery::Disk.new(root: parent, key: SecureRandom.random_bytes(32), signer: @status_signer, quota: 32)
      pins = roots.transform_values { |path| Railpress::Recovery::Disk.pin(path) }
      refute_empty store.inventory!(pins)
      assert_refusal("disk_quota") { store.send(:reserve!, parent, 33, 0) }
      File.rename(roots["media"], roots["media"] + ".original")
      Dir.mkdir(roots["media"], 0o700)
      assert_refusal("disk_mount_identity") { store.inventory!(pins) }
      pins["media"] = Railpress::Recovery::Disk.pin(roots["media"])
      path = File.join(roots["media"], "writable")
      File.write(path, "synthetic bytes")
      File.chmod(0o666, path)
      assert_raises(Railpress::Releases::Invalid) { store.inventory!(pins) }
    end
  end

  test "Disk decryption authenticates both bytes and inventory binding" do
    Dir.mktmpdir("disk-ciphertext-", @operator_root) do |parent|
      store = Railpress::Recovery::Disk.new(root: parent, key: SecureRandom.random_bytes(32), signer: @status_signer)
      clear, encrypted, restored = %w[clear encrypted restored].map { |name| File.join(parent, name) }
      File.write(clear, "private synthetic data")
      store.send(:seal, clear, encrypted, "right-binding")
      store.send(:open_box, encrypted, restored, "right-binding", maximum: 128)
      assert_equal File.binread(clear), File.binread(restored)
      assert_raises(Railpress::Releases::Invalid) do
        store.send(:open_box, encrypted, restored + "-wrong", "wrong-binding", maximum: 128)
      end
      refute File.exist?(restored + "-wrong")
      File.open(encrypted, "r+b") do |file|
        file.seek(13)
        changed = file.read(1).getbyte(0) ^ 0xFF
        file.seek(13)
        file.write([ changed ].pack("C"))
      end
      assert_raises(Railpress::Releases::Invalid) do
        store.send(:open_box, encrypted, restored + "-tampered", "right-binding", maximum: 128)
      end
    end
  end

  test "withdrawal ledger rejects stale or incomplete coverage and a substituted signer" do
    current = Time.now.to_i
    statement = { "format" => Railpress::Recovery::Revocations::FORMAT, "site" => local_inventory["site"],
      "from" => 5, "through" => 6, "issued_at" => current - 10, "expires_at" => current + 60,
      "events" => [ { "sequence" => 6, "kind" => "module_withdrawn", "module_id" => "neutral-probe" } ] }
    verify = lambda do |data, key = @status_signer, head = 6|
      envelope = Railpress::NativeHost.sign(data, @status_signer)
      Railpress::Recovery::Revocations.verify!(Railpress::Releases.canonical(envelope),
        key: key, site: statement["site"], checkpoint: 5, observed_head: head, now: current)
    end
    assert_equal [ "neutral-probe" ], verify.call(statement)
    assert_refusal("revocation_coverage") { verify.call(statement, @status_signer, 7) }
    assert_refusal("revocation_coverage") { verify.call(statement.merge("events" => [])) }
    assert_raises(Railpress::Releases::Invalid) { verify.call(statement.merge("expires_at" => current - 1)) }
    assert_raises(Railpress::Releases::Invalid) { verify.call(statement, @time_signer) }
  end

  private

  def assert_refusal(code)
    assert_equal code, assert_raises(Railpress::Releases::Invalid) { yield }.message
  end

  def successor_manifest
    fixture = altered_fixture do |manifest|
      manifest["format"] = "railpress.release.v2"
      manifest["files"]["lib/railpress/releases/package_context.rb"] = {
        "sha256" => "f" * 64, "bytes" => 1, "mode" => 0o644
      }
      manifest["package_policy"] = { "extension_api" => 1,
        "predecessor" => { "min" => Railpress::Product::VERSION, "max_exclusive" => "2.0.0-alpha.4" },
        "dusk" => @theme_contract.first }
    end
    Railpress::Releases::Manifest.validate!(fixture.fetch("manifest"))
  end

  def local_inventory
    window = { "min" => Railpress::Product::VERSION, "max_exclusive" => "3.0.0" }
    { "format" => Railpress::Releases::PackageContext::FORMAT, "site" => "be9636c2-371c-4788-954f-ab12c48ebd3b",
      "core" => Railpress::Product::VERSION, "anchor" => Railpress::Product::VERSION, "extension_api" => 1, "generation" => 1, "fingerprint" => "b" * 64,
      "modules" => [ { "id" => "neutral-probe", "version" => "1.0.0", "package" => "a" * 64, "manifest" => "c" * 64,
        "schema" => 1, "jobs" => 1, "enabled" => true, "presence" => "installed", "core" => window,
        "data" => %w[schema_read schema_write jobs_read jobs_write].index_with { [ 0, 3 ] },
        "jobs_classes" => [ "NeutralProbe::ProbeJob" ] } ],
      "themes" => [ @theme_contract.first.merge("schema" => 1, "overlays" => []) ], "jobs" => [ "NeutralProbe::ProbeJob" ] }
  end
end
