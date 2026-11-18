require "test_helper"

class MigrationFailureTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "failed forward migration records genuine engine DDL behavior" do
    connection = ActiveRecord::Base.connection
    context = ActiveRecord::MigrationContext.new(Rails.root.join("test/support/failure_migrations").to_s)
    error = assert_raises(StandardError) { context.up }
    assert_match(/DELIBERATELY|syntax/i, error.message)
    persists = connection.table_exists?("m01_failure_probe")
    expected = ENV.fetch("RAILPRESS_TEST_ENGINE") == "mysql2"
    assert_equal expected, persists, "DDL persistence must reflect native engine behavior"
    refute_includes context.get_all_versions, 20261111999999
    puts "FORWARD FAILURE OBSERVATION: adapter=#{ENV.fetch('RAILPRESS_TEST_ENGINE')} partial_table_persisted=#{persists} migration_recorded=false"
  ensure
    connection&.drop_table(:m01_failure_probe, if_exists: true)
  end
end
