# frozen_string_literal: true

require "json"
require "pathname"

module Railpress
  # Refuses unidentified fixture/migration targets before framework connection setup.
  module TestDatabase
    class UnsafeTarget < StandardError; end
    ENGINES = {
      "postgresql" => { "suffix" => "pg", "major" => "16.", "port" => 55436 },
      "mysql2" => { "suffix" => "mysql", "major" => "8.4.", "port" => 55404 }
    }.freeze
    PROFILES = { "native_probe" => "ci_000000000001", "qualification_probe" => "ci_a17000000002", "site_qualification" => "ci_a17000000003", "m15_source" => "ci_15a0ce000001", "m15_target" => "ci_15a0ce000002", "m16_source" => "ci_16a0ce000001", "m16_target" => "ci_16a0ce000002",
      "recovery" => "ci_a08100000001", "recovery_source" => "ci_a08100000002", "recovery_target" => "ci_a08100000003",
      "deadline" => "ci_a09100000001", "deadline_probe" => "ci_a09100000002", "deadline_control" => "ci_a09100000003",
      "deadline_focused" => "ci_a09100000004", "deadline_full" => "ci_a09100000005",
      "reliability_probe" => "ci_a09200000001", "reliability_focus" => "ci_a09200000002", "reliability_full" => "ci_a09200000003",
      "reliability_signal" => "ci_a09200000004", "reliability_signal_fixed" => "ci_a09200000005", "reliability_install" => "ci_a09200000006",
      "hardening_focus" => "ci_a09400000001", "hardening_full" => "ci_a09400000002", "hardening_empty" => "ci_a09400000003",
      "hardening_fixed" => "ci_a09400000004",
      "news_trace" => "ci_a09500000001", "news_focus" => "ci_a09500000002", "news_full" => "ci_a09500000003",
      "gcs_source" => "ci_a09600000001", "gcs_good" => "ci_a09600000002", "gcs_bad" => "ci_a09600000003",
      "gcs_focus" => "ci_a09600000004", "gcs_full" => "ci_a09600000005",
      "gcs_r1_focus" => "ci_a09610000001", "gcs_r1_full" => "ci_a09610000002", "gcs_r1_target" => "ci_a09610000003",
      "gcs_r2_focus" => "ci_a09620000001", "gcs_r2_full" => "ci_a09620000002",
      "gcs_r2_probe" => "ci_a09620000003", "gcs_r2_target" => "ci_a09620000004" }.freeze
    PROFILE_PORTS = {
      "ci_a17000000003" => { "postgresql" => 55636, "mysql2" => 55604 },
      "ci_a17000000001" => { "postgresql" => 55636, "mysql2" => 55604 },
      "ci_a17000000002" => { "postgresql" => 55636, "mysql2" => 55604 },
      "ci_16a0ce000001" => { "postgresql" => 55426, "mysql2" => 55394 },
      "ci_16a0ce000002" => { "postgresql" => 55426, "mysql2" => 55394 }
    }.freeze
    module_function

    def registry_file(profile)
      raise UnsafeTarget, "Unknown synthetic qualification profile" if profile && !PROFILES.key?(profile)
      return "test-targets.json" unless profile
      return "site-test-targets.json" if profile == "site_qualification"
      return "probe-test-targets.json" if %w[native_probe qualification_probe].include?(profile)
      return "recovery-test-targets.json" if profile.start_with?("recovery")
      return "deadline-test-targets.json" if profile.start_with?("deadline")
      return "reliability-test-targets.json" if profile.start_with?("reliability_")
      return "hardening-test-targets.json" if profile.start_with?("hardening_")
      return "news-test-targets.json" if profile.start_with?("news_")
      return "gcs-r2-test-targets.json" if profile.start_with?("gcs_r2_")
      return "gcs-r1-test-targets.json" if profile.start_with?("gcs_r1_")
      return "gcs-test-targets.json" if profile.start_with?("gcs_")
      profile.start_with?("m16_") ? "m16-test-targets.json" : "m15-test-targets.json"
    end

    def validate!(config, environment:, confirmed:)
      raise UnsafeTarget, "Explicit synthetic confirmation required" unless confirmed == "railpress-synthetic-only"
      raise UnsafeTarget, "Only test environment permitted" unless environment == "test"
      expected = ENGINES[config["adapter"]]
      raise UnsafeTarget, "Unsupported adapter" unless expected
      raise UnsafeTarget, "Only loopback test hosts permitted" unless config["host"] == "127.0.0.1"
      run_id = config.fetch("run_id", "m01")
      raise UnsafeTarget, "Invalid synthetic run ID" unless /\A(?:m01|ci_[a-f0-9]{12})\z/.match?(run_id)
      role = "railpress_#{run_id}_#{expected.fetch('suffix')}"
      raise UnsafeTarget, "Unexpected database or role" unless config["database"] == "#{role}_test" && config["username"] == role
      port = PROFILE_PORTS.fetch(run_id, {}).fetch(config["adapter"], expected["port"])
      raise UnsafeTarget, "Invalid test port" unless Integer(config["port"]) == port
      raise UnsafeTarget, "Missing instance identity" unless %w[password instance_id marker_token data_directory].all? { |key| config[key].is_a?(String) && !config[key].empty? }
      true
    rescue ArgumentError, TypeError
      raise UnsafeTarget, "Invalid test port"
    end

    def load!(root:, engine:, environment: ENV.fetch("RAILS_ENV", "test"), confirmed: ENV["RAILPRESS_TEST_CONFIRM"], profile: ENV["RAILPRESS_TEST_PROFILE"])
      root = Pathname(root).realpath
      raise UnsafeTarget, "Unknown synthetic qualification profile" if profile && !PROFILES.key?(profile)
      path = root.join(".local/state", registry_file(profile))
      raise UnsafeTarget, "Missing private synthetic registry" unless path.file?
      raise UnsafeTarget, "Registry must stay within destination" unless path.realpath.to_s.start_with?("#{root}/.local/")
      raise UnsafeTarget, "Registry must be private and owned by current user" unless path.stat.uid == Process.uid && (path.stat.mode & 0o077).zero?
      raise UnsafeTarget, "Inherited DATABASE_URL prohibited" if ENV["DATABASE_URL"]
      raise UnsafeTarget, "Non-test DB connection settings prohibited" if ENV.keys.any? { |key| key.start_with?("RAILPRESS_DB_") }
      registry = JSON.parse(path.read)
      registry = registry.fetch(profile) { raise UnsafeTarget, "Missing synthetic qualification profile" } if profile
      config = registry.fetch(engine) { raise UnsafeTarget, "Unknown engine" }
      raise UnsafeTarget, "Unexpected synthetic profile identity" if profile && config["run_id"] != PROFILES.fetch(profile)
      validate!(config, environment: environment, confirmed: confirmed)
      data = Pathname(config.fetch("data_directory")).realpath
      raise UnsafeTarget, "Synthetic data outside destination" unless data.to_s.start_with?("#{root}/.local/state/") && data.stat.uid == Process.uid
      config
    rescue JSON::ParserError, Errno::ENOENT => error
      raise UnsafeTarget, "Invalid synthetic registry: #{error.class}"
    end

    def verify!(config, confirmed: ENV["RAILPRESS_TEST_CONFIRM"], environment: ENV.fetch("RAILS_ENV", "test"))
      validate!(config, environment: environment, confirmed: confirmed)
      expected = ENGINES.fetch(config.fetch("adapter"))
      if config["adapter"] == "postgresql"
        require "pg"
        connection = PG.connect(host: config["host"], port: config["port"], dbname: config["database"], user: config["username"], password: config["password"], connect_timeout: 3, sslmode: "disable")
        row = connection.exec("SELECT current_database() AS database, current_user AS username, current_setting('server_version') AS version, system_identifier::text AS instance_id, (SELECT token FROM railpress_test_guard.identity) AS marker_token, (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()) AS owner, (SELECT rolsuper FROM pg_roles WHERE rolname=current_user) AS superuser FROM pg_control_system()").first
        raise UnsafeTarget, "Unexpected PostgreSQL ownership or privilege" unless row["owner"] == config["username"] && row["superuser"] == "f"
      else
        require "mysql2"
        connection = Mysql2::Client.new(host: config["host"], port: config["port"], database: config["database"], username: config["username"], password: config["password"], connect_timeout: 3, read_timeout: 3, write_timeout: 3, ssl_mode: :required)
        row = connection.query("SELECT DATABASE() AS db_name, SUBSTRING_INDEX(CURRENT_USER(),'@',1) AS username, VERSION() AS version, @@server_uuid AS instance_id, (SELECT token FROM railpress_m01_guard.identity) AS marker_token, @@datadir AS data_directory").first
        row["database"] = row.delete("db_name")
        raise UnsafeTarget, "Unexpected MySQL data directory" unless File.realpath(row["data_directory"]) == File.realpath(config["data_directory"])
        grants = connection.query("SHOW GRANTS").map(&:values).flatten
        raise UnsafeTarget, "Unexpected MySQL global privilege" if grants.any? { |grant| grant.include?(" ON *.* ") && !grant.start_with?("GRANT USAGE ") }
      end
      keys = %w[database username instance_id marker_token]
      raise UnsafeTarget, "Database identity marker mismatch" unless keys.all? { |key| row[key] == config[key] }
      raise UnsafeTarget, "Unqualified engine version" unless row.fetch("version").start_with?(expected["major"])
      row.slice("database", "username", "version", "instance_id").merge("host" => config["host"], "port" => config["port"])
    ensure
      connection&.close
    end
  end
end
