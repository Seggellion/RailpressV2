require "test_helper"

class ForwardUpgradeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "expand migration preserves existing data and old writer" do
    state = PlatformState.create!(scope_name: "upgrade", key_name: "preserved", payload: { "count" => 7 })
    context = ActiveRecord::MigrationContext.new(Rails.root.join("test/support/upgrade_migrations").to_s)
    context.up
    assert ActiveRecord::Base.connection.column_exists?(:platform_states, :qualification_note)
    assert_equal 7, state.reload.payload["count"]
    state.update!(payload: { "count" => 8 })
    assert_equal 8, state.reload.payload["count"]
    assert_includes context.get_all_versions, 20261111999998
  ensure
    state&.destroy!
    connection = ActiveRecord::Base.connection
    connection.remove_column(:platform_states, :qualification_note) if connection.column_exists?(:platform_states, :qualification_note)
    ActiveRecord::SchemaMigration.new(ActiveRecord::Base.connection_pool).delete_version("20261111999998")
    PlatformState.reset_column_information
  end
end
