# frozen_string_literal: true

module Installation
  module DatabaseProbe
    class Unavailable < StandardError; end
    class Unsafe < StandardError; end
    module_function

    def call
      config = Configuration.active
      raise Unsafe, "Only PostgreSQL and MySQL are supported." unless %w[postgresql mysql2].include?(config["adapter"])
      local = %w[127.0.0.1 localhost ::1].include?(config["host"])
      secure = config["adapter"] == "postgresql" ? config["sslmode"] == "verify-full" && File.file?(config["sslrootcert"].to_s) : config["ssl_mode"].to_s == "verify_identity" && File.file?(config["sslca"].to_s)
      raise Unsafe, "Remote databases require operator-provisioned hostname-verified TLS." unless local || secure
      if config["adapter"] == "postgresql"
        postgres(config)
      else
        mysql(config)
      end
    rescue Unsafe
      raise
    rescue StandardError
      raise Unavailable, "The configured database could not be verified. Ask the operator to check its connection and permissions.", cause: nil
    end

    def postgres(config)
      require "pg"
      args = config.slice("host", "port", "database", "username", "password", "sslmode", "sslrootcert")
      args["dbname"] = args.delete("database"); args["user"] = args.delete("username")
      db = PG.connect(**args.symbolize_keys, connect_timeout: 3, options: "-c statement_timeout=3000 -c lock_timeout=1500")
      raise Unsafe, "Use a scoped application role, not a superuser." if db.exec("SELECT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) AS privileged FROM pg_roles WHERE rolname=current_user").first.fetch("privileged") == "t"
      raise Unsafe, "The application role needs permission to create its dedicated schema." unless db.exec("SELECT has_schema_privilege(current_user,current_schema(),'CREATE') AS allowed").first.fetch("allowed") == "t"
      tables = db.exec("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname=current_schema()").map { |row| row.fetch("tablename") }
      inspect_tables(config, tables) { |table| db.exec("SELECT COUNT(*) AS total FROM #{db.quote_ident(table)}").first.fetch("total").to_i }
    ensure
      db&.close
    end

    def mysql(config)
      require "mysql2"
      args = config.slice("host", "port", "database", "username", "password", "ssl_mode", "sslca").symbolize_keys
      args[:ssl_mode] = args[:ssl_mode].to_sym if args[:ssl_mode]
      db = Mysql2::Client.new(**args, connect_timeout: 3, read_timeout: 3, write_timeout: 3)
      grants = db.query("SHOW GRANTS").map(&:values).flatten
      raise Unsafe, "Use a scoped application role without global privileges." if grants.any? { |grant| grant.include?(" ON *.* ") && !grant.start_with?("GRANT USAGE ") }
      scope = " ON `#{config.fetch('database')}`.* "
      allowed = grants.find { |grant| grant.include?(scope) }
      needed = %w[SELECT INSERT UPDATE DELETE CREATE ALTER INDEX DROP]
      raise Unsafe, "The scoped database role lacks required schema/data privileges." unless allowed && (allowed.include?("ALL PRIVILEGES") || needed.all? { |word| allowed.match?(/\b#{word}\b/) })
      tables = db.query("SHOW TABLES").map(&:values).flatten
      inspect_tables(config, tables) { |table| db.query("SELECT COUNT(*) AS total FROM `#{table.gsub('`', '``')}`").first.fetch("total").to_i }
    ensure
      db&.close
    end

    def allowed_tables(config = Configuration.active)
      path = Rails.root.join("db/schema_#{config.fetch('adapter')}.rb")
      File.read(path).scan(/create_table "([a-z0-9_]+)"/).flatten + %w[schema_migrations ar_internal_metadata]
    end

    def inspect_tables(config, tables)
      unknown = tables - allowed_tables(config)
      raise Unsafe, "The database contains unrelated tables. No schema change was attempted." if unknown.any?
      %w[sites users].each do |table|
        raise Unsafe, "Existing site/account data requires explicit operator reconciliation." if tables.include?(table) && yield(table).positive?
      end
      { "adapter" => config.fetch("adapter"), "connected" => true, "schema" => (tables.empty? ? "empty" : "recognized"), "table_count" => tables.length,
        "configuration" => Configuration.fingerprint, "observed_at" => Time.current.utc.iso8601(6) }
    end
  end
end
