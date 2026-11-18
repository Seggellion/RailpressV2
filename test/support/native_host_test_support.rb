require "railpress/native_host"

module NativeHostTestSupport
  def with_native_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, &replacement)
    yield
  ensure
    target.define_singleton_method(name, original) if original
  end
  def native_setup
    parent = Rails.root.join(".local/state/m12-tests")
    FileUtils.mkdir_p(parent, mode: 0o700)
    @native_root = Dir.mktmpdir("host-", parent)
    %w[releases shared run logs proxy snapshots approvals inbox staging receipts clock].each { |name| Dir.mkdir(File.join(@native_root, name), 0o700) }
    %w[bootstrap themes media assets].each { |name| Dir.mkdir(File.join(@native_root, "shared", name), 0o700) }
    Dir.children(@private_root).each do |name|
      path = File.join(@private_root, name)
      FileUtils.cp(path, File.join(@native_root, "shared", "bootstrap", name)) if File.file?(path) && !File.symlink?(path)
    end
    target = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
    @native_env = {
      "RAILS_ENV" => "production", "SECRET_KEY_BASE" => SecureRandom.hex(64),
      "RAILPRESS_HTTPS_ORIGIN" => "https://localhost:59107",
      "RAILPRESS_PRIVATE_STATE_ROOT" => File.join(@native_root, "shared/bootstrap"),
      "RAILPRESS_STORAGE_ROOT" => File.join(@native_root, "shared/media"),
      "RAILPRESS_THEME_ROOT" => File.join(@native_root, "shared/themes"),
      "RAILPRESS_RELEASE_PUBLIC_TRUST" => File.join(@native_root, "public-trust.json"),
      "RAILPRESS_NATIVE_PUBLIC_STATUS" => File.join(@native_root, "public-status.json"),
      "RAILPRESS_NATIVE_PROBE_TOKEN" => SecureRandom.hex(32), "RAILPRESS_TLS_PROXY_IPS" => "127.0.0.1"
    }
    { "ADAPTER" => "adapter", "HOST" => "host", "PORT" => "port", "NAME" => "database", "USER" => "username", "PASSWORD" => "password" }.each do |key, field|
      @native_env["RAILPRESS_DB_#{key}"] = target[field].to_s
    end
    bytes = JSON.generate(@native_env)
    Railpress::NativeHost::F.atomic(File.join(@native_root, "shared/environment.json"), bytes)
    mysql_bin = File.join(ENV.fetch("RAILPRESS_MYSQL_HOME"), "bin")
    pg_bin = ENV.fetch("RAILPRESS_PG_BIN")
    tools = target["adapter"] == "postgresql" ? { "dump" => "#{pg_bin}/pg_dump", "restore" => "#{pg_bin}/pg_restore", "client" => "#{pg_bin}/psql" } :
      { "dump" => "#{mysql_bin}/mysqldump", "restore" => "#{mysql_bin}/mysql", "client" => "#{mysql_bin}/mysql" }
    @native_document = { "format" => "railpress.native-host.v1", "deployment_id" => SecureRandom.uuid,
      "install_id" => Site.first.install_id, "registry_root" => Rails.root.to_s, "engine" => target["adapter"],
      "database_instance_id" => target["instance_id"], "environment_sha256" => Digest::SHA256.hexdigest(bytes),
      "nginx_binary" => ENV.fetch("RAILPRESS_NGINX_BIN"), "ruby_binary" => RbConfig.ruby,
      "db_tools" => tools, "edge_port" => 59107, "puma_ports" => [ 59110, 59111 ],
      "dependency_hashes" => %w[Gemfile Gemfile.lock].to_h { |name| [ name, Digest::SHA256.file(Rails.root.join(name)).hexdigest ] },
      "scope" => "isolated-synthetic-nginx-v1", "max_snapshot_age_seconds" => 3600 }
    @native_document["test_database_profile"] = ENV["RAILPRESS_TEST_PROFILE"] if ENV["RAILPRESS_TEST_PROFILE"]
    native_write_config
    @native_config = Railpress::NativeHost::Config.new(@native_root)
    @native_db = Railpress::NativeHost::Database.new(@native_config)
    @native_signer = OpenSSL::PKey.generate_key("ED25519")
    Railpress::NativeHost::F.atomic(File.join(@native_root, "synthetic-signing-public.pem"), @native_signer.public_to_pem)
    @native_trust = Railpress::Releases::Authority.new({ "format" => "railpress.trust.v1", "generation" => 1,
      "keys" => { Railpress::Releases.key_id(@native_signer) => { "purpose" => "status", "public_key" => @native_signer.public_to_pem } }, "revoked" => [] })
    @native_trust_state = { "trust_generation" => 0, "revoked" => [], "utc_max" => 0 }
    @native_trust.apply!(@native_trust_state)
    @snapshot = Railpress::NativeHost::Snapshot.new(@native_config, signer: @native_signer)
  end
  def native_write_config
    Railpress::NativeHost::F.atomic(File.join(@native_root, "host.json"), JSON.generate(@native_document))
  end
  def native_teardown
    return unless @native_root && File.directory?(@native_root)
    raise "unsafe native test cleanup" unless File.realpath(@native_root).start_with?(Rails.root.join(".local/state/m12-tests").realpath.to_s + "/")
    if !passed?
      failures = self.failures.first(8).map do |failure|
        exception = failure.respond_to?(:error) ? failure.error : failure
        message = exception.message.to_s.gsub(%r{(?:postgres(?:ql)?|mysql|https?)://[^\s/@]+:[^\s/@]+@}, "[REDACTED]@").byteslice(0, 4096).force_encoding("UTF-8").scrub
        { "class" => exception.class.name, "message" => message, "backtrace" => Array(exception.backtrace).first(32) }
      end
      Railpress::NativeHost::F.atomic(File.join(@native_root, "test-failure.json"), JSON.generate({ "test" => name, "failures" => failures }))
      begin
        tables = @native_db.table_names
        inventory = { "tables" => tables, "counts" => tables.to_h { |table|
          [ table, @native_db.query("SELECT COUNT(*) AS n FROM #{@native_db.quote_identifier(table)}").first.fetch("n").to_i ] } }
        @native_db.connection do |client, engine|
          integrity = @native_db.integrity
          integrity.instance_variable_set(:@client, client)
          inventory["foreign_keys"] = integrity.foreign_keys
        end
        Railpress::NativeHost::F.atomic(File.join(@native_root, "database-failure-inventory.json"), JSON.generate(inventory))
      rescue StandardError => error
        Railpress::NativeHost::F.atomic(File.join(@native_root, "database-failure-inventory.json"), JSON.generate({ "unavailable" => error.class.name }))
      end
      puts "NATIVE_FAILURE_ARTIFACTS: retained private fixture #{@native_root}; no credentials emitted"
      return
    end
    Dir.glob(File.join(@native_root, "**", "*"), File::FNM_DOTMATCH).each { |p| File.chmod(0o700, p) if File.directory?(p) && !File.symlink?(p) }
    FileUtils.remove_entry_secure(@native_root)
  end
  def snapshot_create
    clock = Railpress::SecurityClock.new(@native_env["RAILPRESS_PRIVATE_STATE_ROOT"]).sample
    @snapshot.create!(id: SecureRandom.uuid, active: "a" * 64,
      contract: { "schema" => 11, "write" => 11, "jobs" => 1, "theme_api" => 1 },
      clock_binding: Digest::SHA256.hexdigest(clock["domain"] + clock["epoch"]), site_report: {
        "theme" => nil, "media_reference_fingerprint_full" => @native_db.media_reference_fingerprint,
        "media_reference_fingerprint_permanent" => @native_db.media_reference_fingerprint(permanent: true) })
  end
  def snapshot_validate(id, **options)
    @snapshot.validate!(id, trust: @native_trust, trust_state: @native_trust_state, **options)
  end
end
