# frozen_string_literal: true

require_relative "../lib/railpress/test_database"

module Railpress
  module DatabaseConfiguration
    module_function

    def build(environment = ENV.fetch("RAILS_ENV", "development"))
      raise ArgumentError, "DATABASE_URL is unsupported; use explicit RAILPRESS_DB_* configuration" if ENV["DATABASE_URL"]
      if environment == "test"
        target = TestDatabase.load!(root: File.expand_path("..", __dir__), engine: ENV.fetch("RAILPRESS_TEST_ENGINE", ""))
        TestDatabase.verify!(target)
        return connection_options(target).merge("schema_dump" => "schema_#{target.fetch('adapter')}.rb")
      end
      adapter = ENV.fetch("RAILPRESS_DB_ADAPTER", "postgresql")
      raise ArgumentError, "Only postgresql/mysql2 supported" unless %w[postgresql mysql2].include?(adapter)
      configured = ENV["RAILPRESS_DB_NAME"]
      target = {
        "adapter" => adapter, "host" => ENV.fetch("RAILPRESS_DB_HOST", "127.0.0.1"),
        "port" => Integer(ENV.fetch("RAILPRESS_DB_PORT", configured ? (adapter == "postgresql" ? "5432" : "3306") : "65432")),
        "database" => configured || "railpress_unconfigured", "username" => ENV.fetch("RAILPRESS_DB_USER", "railpress_unconfigured"),
        "password" => ENV.fetch("RAILPRESS_DB_PASSWORD", "")
      }
      options = connection_options(target)
      unless %w[127.0.0.1 localhost ::1].include?(target["host"])
        ca = ENV.fetch("RAILPRESS_DB_SSL_CA") { raise ArgumentError, "Remote DB requires explicit trusted CA file" }
        raise ArgumentError, "CA file missing" unless File.file?(ca)
        options.merge!(adapter == "postgresql" ? { "sslmode" => "verify-full", "sslrootcert" => ca } : { "ssl_mode" => "verify_identity", "sslca" => ca })
      end
      options
    end

    def connection_options(target)
      keys = %w[adapter host port database username password]
      options = target.slice(*keys).merge("encoding" => (target["adapter"] == "postgresql" ? "unicode" : "utf8mb4"), "pool" => Integer(ENV.fetch("RAILS_MAX_THREADS", "5")))
      if target["adapter"] == "mysql2"
        options["collation"] = "utf8mb4_0900_bin"
        options["ssl_mode"] = "required" if target["marker_token"] # Only isolated loopback fixtures; remote uses verified identity.
      end
      options
    end
  end
end
