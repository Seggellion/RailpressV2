require "test_helper"
require_relative "../support/extension_test_support"

class ExtensionPlatformTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include ExtensionTestSupport

  setup { prepare_extension_site }
  teardown { cleanup_extension_site }

  test "admission validates signed identity trust scope sequence and dependencies before Ruby" do
    row, directory = stage_package(version: "1.0.0")
    registry = load_extension_set([ row ])
    assert_equal row["manifest_sha256"], registry.entries.fetch(MODULE_ID).manifest.digest
    assert_predicate registry.entries, :frozen?
    assert_not Object.const_defined?(:NeutralProbe, false)

    envelope_path = File.join(directory, "envelope.json")
    envelope = JSON.parse(File.read(envelope_path))
    statement = envelope.fetch("statement")
    write_json(envelope_path, sign_extension(statement, @operator_key))
    assert_rejected("key_purpose") { load_extension_registry }
    unknown_key = OpenSSL::PKey.generate_key("ED25519")
    write_json(envelope_path, sign_extension(statement, unknown_key))
    assert_rejected("unknown_publisher") { load_extension_registry }
    write_json(envelope_path, sign_extension(statement.merge("expires_at" => Time.now.to_i - 1), @publisher_key))
    assert_rejected("extension_signature_expired") { load_extension_registry }
    write_json(envelope_path, envelope)
    write_extension_trust(revoked: [ Crypto.key_id(@publisher_key) ])
    assert_rejected("extension_key_revoked") { load_extension_registry }
    write_extension_trust(publisher_scopes: [ "different-module" ])
    assert_rejected("extension_signature_scope") { load_extension_registry }
    write_extension_trust(minimum_sequence: 2)
    assert_rejected("integer_range") { load_extension_registry }
    write_extension_trust

    dependency = { "other-engine" => { "min" => "1.0.0", "max_exclusive" => "2.0.0" } }
    dependent, = stage_package(version: "1.1.0", manifest_changes: { "dependencies" => dependency })
    assert_rejected("extension_dependency_order_or_version") { load_extension_set([ dependent ]) }
    invalid, = stage_package(version: "1.2.0", manifest_changes: { "entrypoint" => "lib/not_the_engine.rb" })
    assert_rejected("extension_entrypoint") { load_extension_set([ invalid ]) }
    assert_not Object.const_defined?(:NeutralProbe, false)
  end

  test "exact inventory rejects changed bytes extra paths mode changes and archive changes" do
    row, directory = stage_package(version: "1.0.0")
    load_extension_set([ row ])
    entrypoint = File.join(directory, "files", row.fetch("entrypoint"))
    bytes = File.binread(entrypoint)
    File.binwrite(entrypoint, bytes.sub("NeutralProbe", "ChangedProbe"))
    assert_rejected("extension_inventory_hash") { load_extension_registry }
    File.binwrite(entrypoint, bytes)
    File.chmod(0o755, entrypoint)
    assert_rejected("extension_inventory_mode") { load_extension_registry }
    File.chmod(0o644, entrypoint)
    extra = File.join(directory, "files/lib/unlisted.rb")
    File.write(extra, "")
    assert_rejected("extension_inventory_extra") { load_extension_registry }
    File.delete(extra)
    archive = File.join(directory, "package.tar.gz")
    packed = File.binread(archive)
    packed.setbyte(0, packed.getbyte(0) ^ 1)
    File.binwrite(archive, packed)
    assert_rejected("extension_archive_hash") { load_extension_registry }
    assert_not Object.const_defined?(:NeutralProbe, false)
  end

  private

  def assert_rejected(code, &block)
    assert_equal code, assert_raises(Ext::Invalid, &block).message
  end
end
