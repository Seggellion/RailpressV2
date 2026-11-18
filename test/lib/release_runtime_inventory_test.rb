require "test_helper"
require_relative "../support/release_test_support"

class ReleaseRuntimeInventoryTest < ActiveSupport::TestCase
  include ReleaseTestSupport

  test "release metadata refuses omission of installer schemas and executable theme smoke dependencies" do
    @release_signer = OpenSSL::PKey.generate_key("ED25519")
    @release_now = Time.utc(2026, 11, 12, 12)
    @theme_contract = [ { "id" => "dusk", "version" => "1.1.3", "digest" => "d" * 64 } ]
    original = build_release.fetch("manifest")
    %w[db/schema_postgresql.rb db/schema_mysql2.rb scripts/themes/smoke.rb scripts/themes/navigation_contract_fixture.rb].each do |path|
      missing = original.deep_dup
      missing.fetch("files").delete(path)
      error = assert_raises(Railpress::Releases::Invalid) { Railpress::Releases::Manifest.validate!(missing) }
      assert_equal "file_inventory", error.message
    end
  end
end
