# frozen_string_literal: true

module Railpress
  module NativeHost
    class Database
      def initialize(config) = @config = config
      def connection
        target, = @config.database!
        if target["adapter"] == "postgresql"
          require "pg"
          client = PG.connect(host: target["host"], port: target["port"], dbname: target["database"],
            user: target["username"], password: target["password"], connect_timeout: 3, sslmode: "disable")
        else
          require "mysql2"
          client = Mysql2::Client.new(host: target["host"], port: target["port"], database: target["database"],
            username: target["username"], password: target["password"], connect_timeout: 3, read_timeout: 5, write_timeout: 5, ssl_mode: :required)
        end
        yield client, target["adapter"]
      ensure
        client&.close
      end
      def query(sql)
        connection { |client, engine| (engine == "postgresql" ? client.exec(sql) : client.query(sql)).to_a }
      end
      def execute(sql)
        connection { |client, engine| engine == "postgresql" ? client.exec(sql) : client.query(sql) }
      end
      def assert_installation!
        rows = query("SELECT install_id FROM sites")
        raise Error, "installation_identity" unless rows.map { |row| row["install_id"] } == [ @config.data["install_id"] ]
      end
      def quote_identifier(name)
        raise Error, "schema_identifier" unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_]{0,62}\z/)
        @config.data["engine"] == "postgresql" ? %("#{name}") : "`#{name}`"
      end
      def table_names
        if @config.data["engine"] == "postgresql"
          query("SELECT tablename AS name FROM pg_tables WHERE schemaname='public'").map { |row| row["name"] }.sort
        else
          query("SHOW TABLES").map { |row| row.values.first }.sort
        end
      end
      def column_metadata(table, column)
        quote_identifier(table)
        quote_identifier(column)
        scope = @config.data["engine"] == "postgresql" ? "table_schema='public'" : "table_schema=DATABASE()"
        row = query("SELECT data_type AS native_type, is_nullable AS native_nullable FROM information_schema.columns WHERE #{scope} AND table_name='#{table}' AND column_name='#{column}'").first
        row && { "data_type" => row["native_type"], "is_nullable" => row["native_nullable"] }
      end
      def column?(table, column) = !column_metadata(table, column).nil?
      def sql_literal(value)
        case value
        when nil then "NULL"
        when Integer then value.to_s
        when String
          raise Error, "schema_value" unless value.bytesize <= 100 && value.match?(/\A[a-zA-Z0-9 _.-]*\z/)
          "'#{value}'"
        else raise Error, "schema_value"
        end
      end
      def client_credentials(id)
        target, = @config.database!
        file = @config.path("run", "database-#{NativeHost.uuid!(id)}.private")
        if target["adapter"] == "postgresql"
          bytes = [ target["host"], target["port"], target["database"], target["username"], target["password"] ].map { |v| v.to_s.gsub("\\", "\\\\").gsub(":", "\\:") }.join(":") + "\n"
          F.atomic(file, bytes)
          env = { "PATH" => "/usr/bin:/bin", "PGPASSFILE" => file, "PGSSLMODE" => "disable" }
          arguments = [ "--host", target["host"], "--port", target["port"].to_s, "--username", target["username"] ]
        else
          raise Error, "synthetic_password_format" unless target["password"].match?(/\A[a-zA-Z0-9_-]+\z/)
          bytes = "[client]\nprotocol=TCP\nhost=#{target['host']}\nport=#{target['port']}\nuser=#{target['username']}\npassword=#{target['password']}\nssl-mode=REQUIRED\n"
          F.atomic(file, bytes)
          env = { "PATH" => "/usr/bin:/bin" }
          arguments = [ "--defaults-file=#{file}", "--no-login-paths" ]
        end
        yield target, env, arguments
      ensure
        File.unlink(file) if file && File.file?(file) && !File.symlink?(file)
      end
      def dump!(id, destination)
        assert_installation!
        client_credentials(id) do |target, env, args|
          if target["adapter"] == "postgresql"
            args += [ "--format=custom", "--no-owner", "--no-acl", "--schema=public", target["database"] ]
          else
            args += [ "--single-transaction", "--quick", "--no-tablespaces", "--set-gtid-purged=OFF", "--skip-add-locks", "--skip-comments", "--hex-blob", "--skip-dump-date", target["database"] ]
          end
          Commands.run([ @config.data["db_tools"]["dump"], *args ], env: env, output: destination,
            log: @config.path("logs", "dump-#{id}.log"), seconds: 30)
        end
      end
      def restore!(*, **)
        raise Error, "legacy_in_place_restore_unsupported"
      end
      def restore_fresh!(id, snapshot, expected_tables:, progress: nil, extra_tables: [])
        @config.database!
        assert_restore_offline!
        raise Error, "fresh_target_populated" unless table_names.empty?
        engine = @config.data.fetch("engine")
        scope = engine == "postgresql" ? "table_schema='public'" : "table_schema=DATABASE()"
        raise Error, "fresh_target_objects" unless query("SELECT table_name FROM information_schema.views WHERE #{scope}").empty?
        scope = engine == "postgresql" ? "routine_schema='public'" : "routine_schema=DATABASE()"
        raise Error, "fresh_target_objects" unless query("SELECT routine_name FROM information_schema.routines WHERE #{scope}").empty?
        if engine == "postgresql"
          pg_schema = postgresql_fresh_schema!
          pg_list = postgresql_restore_list!(id, snapshot)
        end
        progress&.call("REPLAY_SQL")
        client_credentials(id) do |target, env, args|
          if target["adapter"] == "postgresql"
            args += [ "--single-transaction", "--exit-on-error", "--no-owner", "--no-acl", "--use-list", pg_list, "--dbname", target["database"], snapshot ]
            Commands.run([ @config.data["db_tools"]["restore"], *args ], env: env,
              log: @config.path("logs", "restore-#{id}-#{SecureRandom.uuid}.log"), seconds: 30)
          else
            MysqlRestore.new(self, @config).run!(id, target, env, args, snapshot)
          end
          progress&.call("SQL_COMPLETE")
        end
        progress&.call("VERIFY_INSTALLATION")
        assert_installation!
        progress&.call("VERIFY_SCHEMA")
        verified = integrity(extra_tables: extra_tables).verify_schema!
        raise Error, "fresh_table_inventory" if expected_tables.any? && expected_tables.sort != table_names
        if engine == "postgresql" && postgresql_public_schema! != pg_schema
          raise Error, "fresh_public_schema_changed"
        end
        verified
      end
      def postgresql_public_schema!
        target, = @config.database!
        row = query("SELECT n.oid::text AS oid,pg_get_userbyid(n.nspowner) AS owner,n.nspacl::text AS acl,current_user AS role,pg_get_userbyid(d.datdba) AS database_owner,has_schema_privilege(current_user,n.oid,'USAGE') AS usage,has_schema_privilege(current_user,n.oid,'CREATE') AS create FROM pg_namespace n CROSS JOIN pg_database d WHERE n.nspname='public' AND d.datname=current_database()").first
        raise Error, "fresh_public_schema_missing" unless row
        raise Error, "fresh_public_schema_missing" unless row
        unless row["role"] == target["username"] && row["database_owner"] == target["username"] && [ target["username"], "pg_database_owner" ].include?(row["owner"])
          raise Error, "fresh_public_schema_owner"
        end
        raise Error, "fresh_public_schema_privileges" unless row["usage"] == "t" && row["create"] == "t"
        raise Error, "fresh_public_schema_privileges" unless query("SELECT 1 FROM pg_namespace n CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl,acldefault('n',n.nspowner))) a WHERE n.nspname='public' AND a.privilege_type='CREATE' AND a.grantee NOT IN (n.nspowner,(SELECT oid FROM pg_roles WHERE rolname=current_user)) LIMIT 1").empty?
        row
      end
      def postgresql_fresh_schema!
        schema = postgresql_public_schema!
        # Include sequences, types and every namespace-dependent object, rather
        # than treating an empty table list as an empty PostgreSQL schema.
        raise Error, "fresh_target_objects" unless query("SELECT 1 FROM pg_depend WHERE refclassid='pg_namespace'::regclass AND refobjid='public'::regnamespace LIMIT 1").empty?
        raise Error, "fresh_target_schemas" unless query("SELECT 1 FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname NOT IN ('public','information_schema','railpress_test_guard') LIMIT 1").empty?
        schema
      end
      def postgresql_restore_list!(id, snapshot)
        NativeHost.uuid!(id)
        raw = @config.path("run", "pg-list-#{id}.raw")
        selected = @config.path("run", "pg-list-#{id}.selected")
        Commands.run([ @config.data["db_tools"]["restore"], "--list", snapshot ], env: { "PATH" => "/usr/bin:/bin" },
          output: raw, log: @config.path("logs", "pg-list-#{id}.log"), seconds: 30)
        lines = F.read(raw, maximum: 1024 * 1024).lines
        entries = lines.filter_map { |line| match = /\A\d+;\s+\d+\s+\d+\s+SCHEMA\s+-\s+(\S+)(?:\s|$)/.match(line); [ line, match[1] ] if match }
        raise Error, "fresh_archive_schema" unless entries.length == 1 && entries.first.last == "public"
        # Retain the raw TOC and archive unchanged. Only PostgreSQL's expected
        # initial public-schema creation entry is omitted; SQL errors stay fatal.
        F.atomic(selected, lines.map { |line| line == entries.first.first ? "; expected existing public schema: #{line}" : line }.join)
        selected
      end
      def allocated_bytes
        if @config.data["engine"] == "postgresql"
          value = query("SELECT pg_database_size(current_database()) AS bytes").first.fetch("bytes")
        else
          value = query("SELECT COALESCE(SUM(DATA_LENGTH+INDEX_LENGTH),0) AS bytes FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE()").first.fetch("bytes")
        end
        bytes = Integer(value)
        raise Error, "restore_capacity_unknown" if bytes.negative?
        bytes
      rescue KeyError, ArgumentError, TypeError
        raise Error, "restore_capacity_unknown"
      end
      def assert_restore_offline!
        connection do |client, engine|
          run = ->(sql) { (engine == "postgresql" ? client.exec(sql) : client.query(sql)).to_a }
          tables = engine == "postgresql" ? run.call("SELECT tablename AS name FROM pg_tables WHERE schemaname='public'").map { |row| row["name"] } : run.call("SHOW TABLES").map { |row| row.values.first }
          if tables.include?("solid_queue_processes")
            raise Error, "unverified_worker_registration" unless run.call("SELECT pid FROM solid_queue_processes").empty?
          end
          others = if engine == "postgresql"
            run.call("SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid()")
          else
            run.call("SELECT ID FROM information_schema.PROCESSLIST WHERE DB=DATABASE() AND ID<>CONNECTION_ID()")
          end
          raise Error, "restore_target_connected" unless others.empty?
        end
        true
      end
      def integrity(extra_tables: [], strict_core: true)
        DatabaseIntegrity.new(self, @config.data.fetch("engine"), extra_tables: extra_tables, strict_core: strict_core)
      end
      def media_reference_fingerprint(permanent: false)
        columns = %w[id media_asset_id content_id content_revision_id content_preview_id stage theme_overlay_id]
        condition = permanent ? " WHERE content_preview_id IS NULL" : ""
        rows = query("SELECT #{columns.join(',')} FROM media_references#{condition} ORDER BY id")
        normalized = rows.map { |row| columns.to_h { |key| [ key, key == "stage" || row[key].nil? ? row[key] : Integer(row[key]) ] } }
        Digest::SHA256.hexdigest(Releases.canonical(normalized))
      end
      def revoke_restored_credentials!
        assert_installation!
        execute("DELETE FROM media_references WHERE content_preview_id IS NOT NULL")
        %w[user_sessions password_resets content_previews theme_previews navigation_previews].each { |name| execute("DELETE FROM #{quote_identifier(name)}") }
        execute("UPDATE users SET auth_version=auth_version+1")
      end
    end
  end
end
