require "test_helper"
require "railpress/recovery"
require_relative "../support/native_host_test_support"

# PG archive/catalog semantics. MySQL retains its independent compatibility tests.
if ENV.fetch("RAILPRESS_TEST_ENGINE") == "postgresql"
  class NativePostgresqlFreshLoaderTest < ActiveSupport::TestCase
    include IdentityTestSupport
    include NativeHostTestSupport
    class BeforeSql < StandardError; end
    setup do
      install_site!
      native_setup
      main = Railpress::TestDatabase.load!(root: Rails.root, engine: "postgresql")
      probe_profile = main["run_id"] == "ci_a17000000001" ? "qualification_probe" : "native_probe"
      @probe_target = Railpress::TestDatabase.load!(root: Rails.root, engine: "postgresql", profile: probe_profile)
      @probe_config = @native_config.dup
      target = @probe_target
      @probe_config.define_singleton_method(:database!) do
        [ target, Railpress::TestDatabase.verify!(target) ]
      end
      @probe_db = Railpress::NativeHost::Database.new(@probe_config)
      assert_empty @probe_db.table_names
      @archive = @native_config.path("run", "empty-public.dump")
      @probe_db.client_credentials(SecureRandom.uuid) do |_target, env, args|
        Railpress::NativeHost::Commands.run([ @native_document["db_tools"]["dump"], *args, "--format=custom", "--no-owner", "--no-acl", "--schema=public", @probe_target["database"] ],
          env: env, output: @archive, log: @native_config.path("logs", "empty-public-dump.log"), seconds: 30)
      end
      @archive_sha = Digest::SHA256.file(@archive).hexdigest
    end
    teardown do
      assert_equal @archive_sha, Digest::SHA256.file(@archive).hexdigest if @archive_sha
      assert_empty @probe_db.table_names if @probe_db
      native_teardown
    end
    def in_probe_transaction
      @probe_db.connection do |client, _|
        client.exec("BEGIN")
        with_native_method(@probe_db, :connection, proc { |&operation| operation.call(client, "postgresql") }) { yield client }
      ensure
        client.exec("ROLLBACK")
      end
    end
    def intercept_sql(&callback)
      original = Railpress::NativeHost::Commands.method(:run)
      wrapper = proc do |argv, **options|
        argv.include?("--dbname") ? callback.call(argv, options) : original.call(argv, **options)
      end
      with_native_method(Railpress::NativeHost::Commands, :run, wrapper) { yield_restore }
    end
    def yield_restore
      @probe_db.restore_fresh!(SecureRandom.uuid, @archive, expected_tables: [])
    end

    test "initialized public and archive reproduce the exact duplicate schema error" do
      owner = @probe_db.query("SELECT pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname='public'").sole.fetch("owner")
      assert_equal "pg_database_owner", owner
      path = @probe_db.postgresql_restore_list!(SecureRandom.uuid, @archive)
      raw = File.read(path.sub(/\.list\z/, ".raw.list"))
      assert_match(/SCHEMA\s+-\s+public\s/, raw)
      in_probe_transaction do |client|
        error = assert_raises(PG::DuplicateSchema) { client.exec("CREATE SCHEMA public") }
        assert_equal "42P06", error.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
      end
    end

    test "filtered_public_entry prevents duplicate initialization without ignoring SQL errors" do
      before = @probe_db.query("SELECT oid,nspowner,nspacl::text FROM pg_namespace WHERE nspname='public'")
      fired = false
      assert_raises(BeforeSql) do
        intercept_sql do |argv, options|
          fired = true
          assert_includes argv, "--use-list"
          assert_includes argv, "--single-transaction"
          assert_includes argv, "--exit-on-error"
          assert_includes argv, "--no-owner"
          assert_includes argv, "--no-acl"
          refute_includes argv, "--clean"
          refute_includes argv, "--create"
          assert_equal 30, options.fetch(:seconds)
          list = argv.fetch(argv.index("--use-list") + 1)
          assert File.read(list).lines.any? { |line| line.start_with?("; expected existing public schema: ") }
          sql = @native_config.path("run", "filtered.sql")
          Railpress::NativeHost::Commands.run([ argv.first, "--use-list", list, "--no-owner", "--no-acl", "--file", sql, @archive ],
            env: { "PATH" => "/usr/bin:/bin" }, log: @native_config.path("logs", "render-sql.log"), seconds: 30)
          refute_match(/CREATE SCHEMA public|DROP SCHEMA|CASCADE/, File.read(sql))
          raise BeforeSql
        end
      end
      assert fired
      assert_equal before, @probe_db.query("SELECT oid,nspowner,nspacl::text FROM pg_namespace WHERE nspname='public'")
    end

    test "duplicate or unexpected archive schema metadata refuses before loading" do
      %w[public unexpected].each do |name|
        original = Railpress::NativeHost::Commands.method(:run)
        wrapper = proc do |argv, **options|
          result = original.call(argv, **options)
          File.open(options.fetch(:output), "a") { |file| file.puts("9999; 2615 99999 SCHEMA - #{name} fixture") } if argv.include?("--list")
          result
        end
        error = assert_raises(Railpress::NativeHost::Error) do
          with_native_method(Railpress::NativeHost::Commands, :run, wrapper) { @probe_db.postgresql_restore_list!(SecureRandom.uuid, @archive) }
        end
        assert_equal "fresh_archive_schema", error.message
      end
      assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
    end

    test "incorrect real public schema ownership is refused and fixture ownership recovered" do
      base = @probe_target
      socket = File.join(File.dirname(base.fetch("data_directory")), "socket")
      admin = PG.connect(host: socket, port: base["port"], dbname: base["database"], user: base.fetch("operator_username"))
      assert_equal base["instance_id"], admin.exec("SELECT system_identifier::text AS id FROM pg_control_system()").sole.fetch("id")
      before = @probe_db.postgresql_public_schema!
      admin.exec("ALTER SCHEMA public OWNER TO #{@probe_db.quote_identifier(base.fetch('operator_username'))}")
      admin.close
      admin = nil
      error = assert_raises(Railpress::NativeHost::Error) { yield_restore }
      assert_equal "fresh_public_schema_owner", error.message
      assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
    ensure
      admin ||= PG.connect(host: socket, port: @probe_target["port"], dbname: @probe_target["database"], user: @probe_target.fetch("operator_username")) if before
      admin&.exec("ALTER SCHEMA public OWNER TO pg_database_owner")
      assert_equal before, @probe_db.postgresql_public_schema! if before
      admin&.close
    end

    test "nonempty destination refuses before any SQL load" do
      in_probe_transaction do |client|
        client.exec("CREATE TABLE r2_owned_probe(id integer PRIMARY KEY)")
        error = assert_raises(Railpress::NativeHost::Error) { yield_restore }
        assert_equal "fresh_target_populated", error.message
        assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
      end
    end

    test "missing default schema and unexpected create grants are refused" do
      in_probe_transaction do |client|
        client.exec("ALTER SCHEMA public RENAME TO r2_owned_probe")
        error = assert_raises(Railpress::NativeHost::Error) { yield_restore }
        assert_equal "fresh_public_schema_missing", error.message
      end
      in_probe_transaction do |client|
        client.exec("GRANT CREATE ON SCHEMA public TO PUBLIC")
        error = assert_raises(Railpress::NativeHost::Error) { yield_restore }
        assert_equal "fresh_public_schema_privileges", error.message
      end
      assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
    end

    test "unexpected sequences types views and namespaces refuse before loading" do
      [ "CREATE SEQUENCE r2_owned_probe", "CREATE TYPE r2_owned_probe AS ENUM ('fixture')",
        "CREATE VIEW r2_owned_probe AS SELECT 1 AS id", "CREATE SCHEMA r2_owned_probe" ].each do |sql|
        in_probe_transaction do |client|
          client.exec(sql)
          error = assert_raises(Railpress::NativeHost::Error) { yield_restore }
          assert_includes %w[fresh_target_objects fresh_target_schemas], error.message
        end
      end
      assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
    end

    test "SQL errors roll back partial DDL and real foreign keys enforce relationships" do
      in_probe_transaction do |client|
        client.exec("CREATE TABLE r2_owned_probe(id integer PRIMARY KEY)")
        client.exec("CREATE TABLE r2_owned_child(id integer REFERENCES r2_owned_probe(id))")
        error = assert_raises(PG::ForeignKeyViolation) { client.exec("INSERT INTO r2_owned_child VALUES (987654)") }
        assert_equal "23503", error.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
      end
      assert_nil @probe_db.query("SELECT to_regclass('public.r2_owned_probe')::text AS name").sole.fetch("name")
      in_probe_transaction do |client|
        client.exec("CREATE TABLE r2_owned_probe(id integer)")
        error = assert_raises(PG::SyntaxError) { client.exec("THIS IS DELIBERATELY INVALID SQL") }
        assert_equal "42601", error.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
      end
      assert_empty @probe_db.table_names
    end

    test "native restore failure propagates without suppressing the original error" do
      failure = Railpress::NativeHost::Error.new("native_command_failed")
      actual = assert_raises(Railpress::NativeHost::Error) { intercept_sql { |_argv, _options| raise failure } }
      assert_same failure, actual
      assert_empty @probe_db.table_names
    end

    test "coordinator retains quarantine after simulated partial load and preserves original real records" do
      ActiveRecord::Base.connection_handler.clear_all_connections!
      original = @native_db.integrity.capture
      source_db = @native_db
      source_data = @native_config.data
      source_identity = @native_config.database!
      source = Object.new
      source.define_singleton_method(:database) { source_db }
      source.define_singleton_method(:data) { source_data }
      source.define_singleton_method(:database!) { source_identity }
      probe_identity = @probe_config.database!
      target_root = @native_config.root
      probe_db = @probe_db
      simulated = Object.new
      marker = File.join(target_root, "run", "simulated-partial-no-sql")
      simulated.define_singleton_method(:restore_fresh!) do |*_, **_|
        File.write(marker, "SIMULATED PARTIAL STATE; no database load")
        raise Railpress::NativeHost::Error, "native_command_failed"
      end
      target = Object.new
      target.define_singleton_method(:data) { source_data }
      target.define_singleton_method(:root) { target_root }
      target.define_singleton_method(:path) { |*parts| File.join(target_root, *parts) }
      target.define_singleton_method(:database) { simulated }
      target.define_singleton_method(:database!) { probe_identity }
      target.define_singleton_method(:empty!) { probe_db.assert_restore_offline!; raise "probe not empty" unless probe_db.table_names.empty? }
      target.define_singleton_method(:lock!) { File.open(File.join(target_root, "run", "coordinator-test.lock"), "w", 0o600) }
      target.define_singleton_method(:data) { source_data }
      target.define_singleton_method(:database!) { probe_identity }
      target.define_singleton_method(:database) { simulated }
      target.define_singleton_method(:empty!) { probe_db.postgresql_fresh_schema! }
      target.define_singleton_method(:lock!) { File.open(File.join(target_root, "run", "unit.lock"), "w") }
      validator = Object.new
      validator.define_singleton_method(:run) { { "checks" => { "fixture_dependencies" => "VERIFIED" } } }
      manifest = { "id" => SecureRandom.uuid, "database" => { "source" => source_identity.last, "engine" => "postgresql", "integrity" => original },
        "site" => { "install_id" => source_data["install_id"] }, "security" => { "password_verifiers_sha256" => Railpress::Recovery.digest(@native_db.query("SELECT id,password_digest FROM users ORDER BY id")) } }
      flow = Railpress::Recovery::Fresh.new(source: source, target: target, manifest: manifest, dump: @archive, validator: validator,
        clock_root: target.path("candidate-private"), app_root: Rails.root.to_s, configuration_files: {}, theme_root: target_root)
      error = assert_raises(Railpress::NativeHost::Error) { flow.run! }
      assert_equal "native_command_failed", error.message
      assert_equal "FAILED/QUARANTINED", flow.receipt["state"]
      assert_equal "QUARANTINED", flow.receipt.fetch("phases").last.fetch("phase")
      assert flow.receipt["original_unchanged"]
      assert File.exist?(marker)
      assert @native_db.integrity.verify!(original)
      assert_empty @probe_db.table_names
      assert_equal "UNAVAILABLE", flow.receipt["promotion"]
    end
  end
end
