require "test_helper"
require_relative "../support/native_host_test_support"
require_relative "../support/editorial_test_support"
class NativePagePathCompatibilityTest < ActiveSupport::TestCase
  include EditorialTestSupport
  include NativeHostTestSupport
  setup { native_setup }
  teardown { native_teardown }
  test "old code revert is refused for private nested Page data and retained revision semantics" do
    schema = Railpress::NativeHost::Schema.new(@native_config)
    manifest = { "compatibility"=>{ "schema_read"=>[ 11, 12 ], "schema_write"=>[ 11, 12 ], "jobs_read"=>[ 1, 1 ], "jobs_write"=>[ 1, 1 ], "security_clock"=>2, "theme_api"=>1 } }
    contract = { "schema"=>11, "write"=>11, "jobs"=>1, "theme_api"=>1 }
    assert schema.revert_eligible!(manifest, contract)
    page = draft("Page", slug: "docs/private-guide", visibility: "private")
    assert_equal "incompatible_revert_page_paths", assert_raises(Railpress::NativeHost::Error) { schema.revert_eligible!(manifest, contract) }.message
    change(page, attributes: { slug: "flat-guide" })
    assert_raises(Railpress::NativeHost::Error) { schema.revert_eligible!(manifest, contract) }
    manifest["files"] = { "lib/railpress/page_path_contract.rb"=>{} }
    assert schema.revert_eligible!(manifest, contract)
    refute page.reload.publicly_visible?
  end
end
