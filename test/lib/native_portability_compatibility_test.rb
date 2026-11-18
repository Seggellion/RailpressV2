require "test_helper"
require_relative "../support/native_host_test_support"
require_relative "../support/portability_test_support"
class NativePortabilityCompatibilityTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include NativeHostTestSupport
  include PortabilityTestSupport
  setup { install_site!; native_setup }
  teardown { native_teardown }
  test "native synthetic profile rejects unknown names without weakening exact database identity" do
    @native_document["test_database_profile"] = "production"
    native_write_config
    assert_equal "unknown_synthetic_database_profile", assert_raises(Railpress::NativeHost::Error) { Railpress::NativeHost::Config.new(@native_root) }.message
  end
  test "old readers cannot revert while private portability state requires the new reader" do
    manifest = { "files"=>{}, "compatibility"=>{ "schema_read"=>[ 11, 12 ], "schema_write"=>[ 11, 12 ], "jobs_read"=>[ 1, 1 ], "jobs_write"=>[ 1, 1 ], "security_clock"=>2, "theme_api"=>1 } }
    contract = { "schema"=>11, "write"=>11, "jobs"=>1, "theme_api"=>1 }
    schema = Railpress::NativeHost::Schema.new(@native_config)
    assert schema.revert_eligible!(manifest, contract)
    submit_portable(portable_manifest, session_id: portability_session)
    assert_equal "incompatible_revert_portability", assert_raises(Railpress::NativeHost::Error) { schema.revert_eligible!(manifest, contract) }.message
    %w[lib/railpress/portability_contract.rb app/jobs/portability_export_job.rb app/jobs/portability_import_job.rb app/services/portability/worker.rb].each { |path| manifest["files"][path] = {} }
    assert schema.revert_eligible!(manifest, contract)
  end
end
