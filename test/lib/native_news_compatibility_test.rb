require "test_helper"
require_relative "../support/native_host_test_support"
class NativeNewsCompatibilityTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include NativeHostTestSupport
  setup { install_site!;native_setup }
  teardown { native_teardown }
  test "native revert refuses code missing enabled provider consumer or pending news job classes" do
    schema=Railpress::NativeHost::Schema.new(@native_config)
    manifest={ "compatibility"=>{ "schema_read"=>[ 11, 12 ], "schema_write"=>[ 11, 12 ], "jobs_read"=>[ 1, 1 ], "jobs_write"=>[ 1, 1 ], "security_clock"=>2, "theme_api"=>1 } }
    contract={ "schema"=>11, "write"=>11, "jobs"=>1, "theme_api"=>1 }
    assert schema.revert_eligible!(manifest, contract)
    row=OfficialNewsState.create!(site: Site.first, enabled: true)
    assert_equal "incompatible_revert_official_news", assert_raises(Railpress::NativeHost::Error) { schema.revert_eligible!(manifest, contract) }.message
    row.update!(enabled: false, provider_enabled: true)
    assert_raises(Railpress::NativeHost::Error) { schema.revert_eligible!(manifest, contract) }
    row.update!(provider_enabled: false)
    original=OfficialNewsRefreshJob.queue_adapter
    begin
      OfficialNewsRefreshJob.queue_adapter=:solid_queue
      job=OfficialNewsRefreshJob.perform_later(row.id, row.generation)
    ensure
      OfficialNewsRefreshJob.queue_adapter=original
    end
    assert job.provider_job_id
    assert_raises(Railpress::NativeHost::Error) { schema.revert_eligible!(manifest, contract) }
    manifest["files"]=%w[app/jobs/official_news_refresh_job.rb app/jobs/official_news_sweep_job.rb app/services/official_news/refresh.rb].to_h { |p|[ p, {} ] }
    assert schema.revert_eligible!(manifest, contract)
  end
end
