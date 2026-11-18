require "test_helper"
require "open3"

class DatabaseTaskSafetyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "raw production migrations and database drop refuse before execution" do
    [ [ "production", "native:migrate_from_zero" ], [ "production", "db:migrate" ], [ "test", "db:drop" ], [ "test", "db:prepare" ], [ "test", "db:seed:replant" ], [ "test", "db:truncate_all" ] ].each do |environment, task|
      output, status = Open3.capture2e({ "RAILS_ENV" => environment }, RbConfig.ruby, "bin/rails", task)
      refute status.success?
      assert_includes output, "REFUSED"
    end
    assert ActiveRecord::Base.connection.table_exists?(:platform_states)
  end

  test "fresh schema reset refuses unexpected tables before dropping known tables" do
    connection = ActiveRecord::Base.connection
    connection.create_table(:m01_unexpected_table) { |t| t.string :value }
    output, status = Open3.capture2e(RbConfig.ruby, "bin/native_test", ENV.fetch("RAILPRESS_TEST_ENGINE"), "--confirm-synthetic", "native:empty_schema")
    refute status.success?
    assert_includes output, "REFUSED: unexpected schema tables"
    output, status = Open3.capture2e(RbConfig.ruby, "bin/native_test", ENV.fetch("RAILPRESS_TEST_ENGINE"), "--confirm-synthetic", "native:migrate_from_zero")
    refute status.success?
    assert_includes output, "REFUSED: fresh migrations require an empty verified application schema"
    assert connection.table_exists?(:platform_states)
    assert connection.table_exists?(:m01_unexpected_table)
  ensure
    connection&.drop_table(:m01_unexpected_table, if_exists: true)
  end

  test "postgres guard rejects actual unexpected database ownership" do
    if ENV.fetch("RAILPRESS_TEST_ENGINE") == "postgresql"
      require "pg"
      config = Railpress::TestDatabase.load!(root: Rails.root, engine: "postgresql")
      operator = PG.connect(host: File.join(File.dirname(config.fetch("data_directory")), "socket"), port: config.fetch("port"), dbname: "postgres", user: config.fetch("operator_username", "railpress_m01_operator"))
      observed = operator.exec("SELECT system_identifier::text AS id FROM pg_control_system()").first.fetch("id")
      assert_equal config.fetch("instance_id"), observed
      operator.exec("ALTER DATABASE #{operator.quote_ident(config.fetch('database'))} OWNER TO #{operator.quote_ident(config.fetch('operator_username', 'railpress_m01_operator'))}")
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.verify!(config) }
    else
      target = Railpress::TestDatabase.load!(root: Rails.root, engine: "mysql2")
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.verify!(target.merge("data_directory" => Rails.root.to_s)) }
    end
  ensure
    if operator
      operator.exec("ALTER DATABASE #{operator.quote_ident(config.fetch('database'))} OWNER TO #{operator.quote_ident(config.fetch('username'))}")
      operator.close
    end
  end
end
