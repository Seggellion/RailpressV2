require "test_helper"
require_relative "../../lib/railpress/test_database"

class TestDatabaseTest < ActiveSupport::TestCase
  def setup
    @config = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
  end

  def validate(config = @config, environment: "test", confirmed: "railpress-synthetic-only")
    Railpress::TestDatabase.validate!(config, environment: environment, confirmed: confirmed)
  end

  test "verified target identifies the actual qualified engine" do
    identity = Railpress::TestDatabase.verify!(@config)
    assert_equal @config["database"], identity["database"]
    assert_equal @config["instance_id"], identity["instance_id"]
    refute identity.key?("password")
    refute identity.key?("marker_token")
  end

  test "missing synthetic confirmation refuses before connection" do
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(confirmed: nil) }
  end

  test "new patch-lane ports require exact fixed qualification identities" do
    engine = @config.fetch("adapter")
    suffix = Railpress::TestDatabase::ENGINES.fetch(engine).fetch("suffix")
    run_id = "ci_16a0ce000002"
    candidate = @config.merge("run_id" => run_id, "database" => "railpress_#{run_id}_#{suffix}_test", "username" => "railpress_#{run_id}_#{suffix}", "port" => engine == "postgresql" ? 55426 : 55394)
    assert validate(candidate)
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(candidate.merge("port" => Railpress::TestDatabase::ENGINES.fetch(engine).fetch("port"))) }
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(candidate.merge("run_id" => "ci_16a0ce000099")) }
    assert_equal "m16-test-targets.json", Railpress::TestDatabase.registry_file("m16_target")
    assert_equal "m15-test-targets.json", Railpress::TestDatabase.registry_file("m15_target")
    assert_equal "test-targets.json", Railpress::TestDatabase.registry_file(nil)
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.registry_file("production") }
  end

  test "independent qualification profiles require their fixed ports and registries" do
    engine = @config.fetch("adapter")
    suffix = Railpress::TestDatabase::ENGINES.fetch(engine).fetch("suffix")
    %w[ci_a17000000001 ci_a17000000002 ci_a17000000003].each do |run_id|
      role = "railpress_#{run_id}_#{suffix}"
      candidate = @config.merge("run_id" => run_id, "database" => "#{role}_test", "username" => role, "port" => engine == "postgresql" ? 55636 : 55604)
      assert validate(candidate)
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(candidate.merge("port" => Railpress::TestDatabase::ENGINES.fetch(engine).fetch("port"))) }
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(candidate.merge("run_id" => "ci_a17000000099")) }
    end
    assert_equal "probe-test-targets.json", Railpress::TestDatabase.registry_file("qualification_probe")
    assert_equal "site-test-targets.json", Railpress::TestDatabase.registry_file("site_qualification")
  end

  test "production and development environments refuse" do
    %w[production development].each { |environment| assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(environment: environment) } }
  end

  test "recovery profiles use new fixed identities without repointing default registries" do
    %w[recovery recovery_source recovery_target].each do |profile|
      run_id = Railpress::TestDatabase::PROFILES.fetch(profile)
      suffix = Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("suffix")
      role = "railpress_#{run_id}_#{suffix}"
      candidate = @config.merge("run_id" => run_id, "database" => "#{role}_test", "username" => role, "port" => Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("port"))
      assert validate(candidate)
      assert_equal "recovery-test-targets.json", Railpress::TestDatabase.registry_file(profile)
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(candidate.merge("database" => @config["database"])) } unless candidate["database"] == @config["database"]
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(candidate.merge("port" => 55417)) }
    end
    assert_equal "test-targets.json", Railpress::TestDatabase.registry_file(nil)
  end

  test "deadline profiles preserve existing registries and use distinct fixed identities" do
    %w[deadline deadline_probe deadline_control deadline_focused deadline_full].each do |profile|
      run_id = Railpress::TestDatabase::PROFILES.fetch(profile)
      suffix = Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("suffix")
      role = "railpress_#{run_id}_#{suffix}"
      candidate = @config.merge("run_id" => run_id, "database" => "#{role}_test", "username" => role, "port" => Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("port"))
      assert validate(candidate)
      assert_equal "deadline-test-targets.json", Railpress::TestDatabase.registry_file(profile)
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(candidate.merge("port" => 55417)) }
    end
    assert_equal "test-targets.json", Railpress::TestDatabase.registry_file(nil)
    assert_equal "recovery-test-targets.json", Railpress::TestDatabase.registry_file("recovery")
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.registry_file("deadline_unknown") }
  end

  test "reliability profiles isolate new experiments without changing earlier registries" do
    %w[reliability_probe reliability_focus reliability_full reliability_signal reliability_signal_fixed reliability_install].each do |profile|
      run_id = Railpress::TestDatabase::PROFILES.fetch(profile)
      suffix = Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("suffix")
      role = "railpress_#{run_id}_#{suffix}"
      assert validate(@config.merge("run_id" => run_id, "database" => "#{role}_test", "username" => role, "port" => Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("port")))
      assert_equal "reliability-test-targets.json", Railpress::TestDatabase.registry_file(profile)
    end
    assert_equal "deadline-test-targets.json", Railpress::TestDatabase.registry_file("deadline")
    assert_equal "recovery-test-targets.json", Railpress::TestDatabase.registry_file("recovery")
    assert_equal "test-targets.json", Railpress::TestDatabase.registry_file(nil)
  end

  test "source and unknown database names refuse" do
    %w[ultimacraft_test railpress_production unknown].each do |name|
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(@config.merge("database" => name)) }
    end
  end

  test "remote loopback aliases and malformed hosts refuse" do
    [ "db.example.invalid", "localhost", "::1", "127.0.0.2", "127.0.0.1:5432" ].each do |host|
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(@config.merge("host" => host)) }
    end
  end

  test "unsupported adapter and unexpected role refuse" do
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(@config.merge("adapter" => "sqlite3")) }
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(@config.merge("username" => "postgres")) }
  end

  test "invalid port and missing instance identity refuse" do
    [ 0, 543, 5432, 3306, 55417, 65536, "invalid", nil ].each do |port|
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(@config.merge("port" => port)) }
    end
    %w[instance_id marker_token password data_directory].each do |field|
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { validate(@config.merge(field => "")) }
    end
  end

  test "wrong actual instance and schema marker refuse" do
    %w[instance_id marker_token].each do |field|
      assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.verify!(@config.merge(field => "wrong")) }
    end
  end

  test "explicit non-test connection settings refuse before connecting" do
    original = ENV["RAILPRESS_DB_HOST"]
    ENV["RAILPRESS_DB_HOST"] = "db.example.invalid"
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE")) }
  ensure
    ENV["RAILPRESS_DB_HOST"] = original
  end

  test "inherited database URL refuses without displaying credentials" do
    original = ENV["DATABASE_URL"]
    ENV["DATABASE_URL"] = "postgresql://synthetic:do-not-log@127.0.0.1/wrong"
    error = assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE")) }
    refute_includes error.message, "do-not-log"
  ensure
    ENV["DATABASE_URL"] = original
  end
  test "hardening profiles have fixed new identities and preserve old registry selection" do
    %w[hardening_focus hardening_full hardening_empty hardening_fixed].each do |profile|
      run_id = Railpress::TestDatabase::PROFILES.fetch(profile)
      suffix = Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("suffix")
      role = "railpress_#{run_id}_#{suffix}"
      assert validate(@config.merge("run_id" => run_id, "database" => "#{role}_test", "username" => role, "port" => Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("port")))
      assert_equal "hardening-test-targets.json", Railpress::TestDatabase.registry_file(profile)
    end
    assert_equal "reliability-test-targets.json", Railpress::TestDatabase.registry_file("reliability_full")
    assert_equal "test-targets.json", Railpress::TestDatabase.registry_file(nil)
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.registry_file("hardening_unknown") }
  end
  test "news qualification profiles use new fixed identities and a separate registry" do
    %w[news_trace news_focus news_full].each do |profile|
      run_id = Railpress::TestDatabase::PROFILES.fetch(profile)
      suffix = Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("suffix")
      role = "railpress_#{run_id}_#{suffix}"
      assert validate(@config.merge("run_id" => run_id, "database" => "#{role}_test", "username" => role, "port" => Railpress::TestDatabase::ENGINES.fetch(@config.fetch("adapter")).fetch("port")))
      assert_equal "news-test-targets.json", Railpress::TestDatabase.registry_file(profile)
    end
    assert_equal "hardening-test-targets.json", Railpress::TestDatabase.registry_file("hardening_full")
    assert_raises(Railpress::TestDatabase::UnsafeTarget) { Railpress::TestDatabase.registry_file("news_unknown") }
  end
end
