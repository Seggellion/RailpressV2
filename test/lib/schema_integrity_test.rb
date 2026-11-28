require "test_helper"

class SchemaIntegrityTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "uncached guard detects a table without foreign keys being renamed" do
    connection = ActiveRecord::Base.connection
    begin
      connection.execute("ALTER TABLE ar_internal_metadata RENAME TO rp_guard_metadata")
      assert_raises(TestSchemaIntegrity::Unsafe) { TestSchemaIntegrity.verify! }
    ensure
      connection.execute("ALTER TABLE rp_guard_metadata RENAME TO ar_internal_metadata")
    end
    assert TestSchemaIntegrity.verify!
  end

  test "cached enforcement reads cannot hide raw MySQL session changes" do
    connection = ActiveRecord::Base.connection
    if ENV.fetch("RAILPRESS_TEST_ENGINE") == "mysql2"
      connection.cache do
        assert TestSchemaIntegrity.verify!
        begin
          connection.raw_connection.query("SET SESSION foreign_key_checks=0")
          assert_raises(TestSchemaIntegrity::Unsafe) { TestSchemaIntegrity.verify! }
        ensure
          connection.raw_connection.query("SET SESSION foreign_key_checks=1")
        end
      end
    end
    assert TestSchemaIntegrity.verify!
  end

  test "native schema exactly enforces the engine foreign key contract" do
    assert TestSchemaIntegrity.verify!
    expected = TestSchemaIntegrity.expected(ENV.fetch("RAILPRESS_TEST_ENGINE"))
    assert_equal 97, expected.size
    %w[extension_install_requests extension_installations extension_migration_records].each do |table|
      assert_includes expected, [ table, "sites", [ "site_id" ], [ "id" ], "restrict" ]
    end
    assert_includes expected, [ "theme_overlays", "users", [ "author_id" ], [ "id" ], "restrict" ]
    assert_includes expected, [ "theme_uploads", "sites", [ "site_id" ], [ "id" ], "restrict" ]
    assert_includes expected, [ "theme_uploads", "theme_installations", [ "theme_installation_id" ], [ "id" ], "restrict" ]
  end

  test "real orphan inserts are rejected by native constraints in a transaction" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute("INSERT INTO activity_events (site_id, actor_id, actor_name, category, action, outcome, details, created_at) VALUES (999999999, NULL, 'Synthetic R1', 'operations', 'r1_probe', 'succeeded', '{}', CURRENT_TIMESTAMP)")
      end
    end
    assert TestSchemaIntegrity.verify!
  end

  test "guard detects actual native integrity loss and explicit rollback restores the contract" do
    connection = ActiveRecord::Base.connection
    if ENV.fetch("RAILPRESS_TEST_ENGINE") == "postgresql"
      name = connection.foreign_keys("theme_overlays").find { |key| key.column == "author_id" }.name
      ActiveRecord::Base.transaction(requires_new: true) do
        connection.execute("ALTER TABLE theme_overlays DROP CONSTRAINT #{connection.quote_column_name(name)}")
        assert_raises(TestSchemaIntegrity::Unsafe) { TestSchemaIntegrity.verify! }
        assert_output(nil, /qualification aborted; no automatic schema repair/) do
          assert_equal 78, assert_raises(SystemExit) { TestSchemaIntegrity.guard! }.status
        end
        raise ActiveRecord::Rollback
      end
    else
      begin
        connection.execute("SET SESSION foreign_key_checks=0")
        assert_raises(TestSchemaIntegrity::Unsafe) { TestSchemaIntegrity.verify! }
        assert_output(nil, /qualification aborted; no automatic schema repair/) do
          assert_equal 78, assert_raises(SystemExit) { TestSchemaIntegrity.guard! }.status
        end
      ensure
        connection.execute("SET SESSION foreign_key_checks=1")
      end
    end
    assert TestSchemaIntegrity.verify!
  end
end
