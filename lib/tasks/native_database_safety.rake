# frozen_string_literal: true

require_relative "../railpress/test_database"

namespace :native do
  task :verify_test_target do
    abort "REFUSED: database tasks require an explicitly confirmed synthetic test environment" unless ENV["RAILS_ENV"] == "test"
    target = Railpress::TestDatabase.load!(root: File.expand_path("../..", __dir__), engine: ENV.fetch("RAILPRESS_TEST_ENGINE", ""))
    Railpress::TestDatabase.verify!(target)
  end

  desc "Execute every migration on an already empty verified synthetic schema"
  task migrate_from_zero: [ :verify_test_target, :environment ] do
    connection = ActiveRecord::Base.connection
    abort "REFUSED: fresh migrations require an empty verified application schema" unless connection.tables.empty?
    # Rails 8 DatabaseTasks.migrate_all automatically loads a recorded schema on an
    # uninitialized DB. Use the migration context directly to prove every file runs.
    ActiveRecord::Base.connection_pool.migration_context.migrate
    puts "FRESH MIGRATIONS EXECUTED: verified synthetic schema; no schema shortcut"
  end

  desc "Empty only known application tables in a verified disposable test schema"
  task empty_schema: [ :verify_test_target, :environment ] do
    config = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
    schema = Rails.root.join("db/schema_#{config.fetch('adapter')}.rb")
    known = schema.read.scan(/create_table "([^"]+)"/).flatten + %w[schema_migrations ar_internal_metadata]
    connection = ActiveRecord::Base.connection
    tables = connection.tables
    abort "REFUSED: unexpected schema tables" unless (tables - known).empty?
    puts "EMPTY VERIFIED SYNTHETIC SCHEMA: #{config.fetch('database')}; #{tables.size} known application tables; instance marker retained"
    connection.disable_referential_integrity do
      tables.each { |table| connection.drop_table(table, if_exists: true, force: :cascade) }
    end
    connection.schema_cache.clear!
  end
end

# Place identity verification BEFORE Rails' environment/database loading prerequisites.
Rake::Task["db:load_config"].prerequisites.unshift("native:verify_test_target")
# Block all matching existing subtasks as well as their root commands.
blocked = /\Adb:(?:(?:create|drop|purge|reset|setup|prepare|truncate_all)(?::|$)|test:(?:purge|load_schema)(?::|$)|seed:replant(?::|$))/
Rake.application.tasks.select { |candidate| blocked.match?(candidate.name) }.each do |candidate|
  candidate.clear
  candidate.enhance do
    abort "REFUSED: database creation/drop/purge/reset/prepare is operator-only; use verified migrations or schema:load"
  end
end
Rake::Task.define_task("db:test:prepare").clear
task "db:test:prepare" => [ "native:verify_test_target", :environment ] do
  ActiveRecord::Migration.check_pending_migrations
end
