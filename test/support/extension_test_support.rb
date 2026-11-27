require "rubygems/package"
require "open3"
require "timeout"
require "zlib"
require_relative "native_queue_observation"

module ExtensionTestSupport
  Ext = Railpress::Extensions
  Crypto = Railpress::Releases
  MODULE_ID = "neutral-probe"
  SCRATCH_TABLES = %w[rp_ext_neutral_probe_records rp_ext_neutral_probe_schema_migrations rp_ext_neutral_probe_internal_metadata].freeze

  def prepare_extension_site
    TestSchemaIntegrity.verify!
    @extension_config = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
    Railpress::TestDatabase.verify!(@extension_config)
    install_site!
    @extension_site = Site.find_by!(singleton_key: 1)
    @extension_root = File.join(@private_root, "extensions")
    Dir.mkdir(@extension_root, 0o700)
    @publisher_key = OpenSSL::PKey.generate_key("ED25519")
    @operator_key = OpenSSL::PKey.generate_key("ED25519")
    write_extension_trust
    @extension_lock = File.join(@extension_root, "operator.lock")
    File.write(@extension_lock, "", perm: 0o600)
  end

  def write_extension_trust(revoked: [], publisher_scopes: [ MODULE_ID ], minimum_sequence: 1)
    keys = {
      Crypto.key_id(@publisher_key) => { "public_key" => @publisher_key.public_to_pem, "purpose" => Ext::Trust::PACKAGE,
        "scopes" => publisher_scopes, "minimum_sequence" => minimum_sequence },
      Crypto.key_id(@operator_key) => { "public_key" => @operator_key.public_to_pem, "purpose" => Ext::Trust::RECEIPT,
        "scopes" => [ MODULE_ID ], "minimum_sequence" => 1 }
    }
    write_json(File.join(@extension_root, "trust.json"), { "format" => "railpress.extension-trust.v1", "keys" => keys, "revoked" => revoked })
  end

  def sign_extension(statement, key)
    {
      "statement" => statement,
      "signature" => { "algorithm" => "ed25519", "key_id" => Crypto.key_id(key),
        "signature" => Base64.strict_encode64(key.sign(nil, Crypto.canonical(statement))) }
    }
  end

  def stage_package(version:, migration_count: 1, manifest_changes: {}, file_changes: {}, key: @publisher_key)
    fixture = Rails.root.join("test/fixtures/extensions/neutral_probe")
    paths = Dir.glob("**/*", base: fixture).select { |path| fixture.join(path).file? }.sort
    migrations = paths.grep(%r{^db/migrate/}).first(migration_count)
    paths = paths.reject { |path| path.start_with?("db/migrate/") } + migrations
    files = paths.to_h { |path| [ path, fixture.join(path).binread ] }.merge(file_changes)
    entries = files.transform_values { |bytes| { "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize, "mode" => "0644" } }
    manifest = {
      "format" => Ext::Manifest::FORMAT, "id" => MODULE_ID, "name" => "Neutral probe", "version" => version,
      "core" => { "min" => Railpress::Product::VERSION, "max_exclusive" => "3.0.0" }, "extension_api" => [ 1, 1 ],
      "entrypoint" => "lib/neutral_probe/engine.rb", "engine" => "NeutralProbe::Engine", "dependencies" => {},
      "provides" => [ "neutral-probe.probe" ], "routes" => { "public" => true, "admin" => true, "navigation" => "Probe" },
      "permissions" => [], "slots" => [],
      "data_contract" => %w[schema_read schema_write jobs_read jobs_write].index_with { [ 0, 3 ] },
      "license" => "MIT", "provenance" => "Railpress synthetic fixture", "files" => entries,
      "migrations" => migrations.map do |path|
        { "version" => File.basename(path).split("_", 2).first, "path" => path, "sha256" => entries.fetch(path).fetch("sha256") }
      end
    }.merge(manifest_changes)
    buffer = StringIO.new("".b)
    Gem::Package::TarWriter.new(buffer) do |archive|
      files.each { |path, bytes| archive.add_file_simple(path, 0o644, bytes.bytesize) { |file| file.write(bytes) } }
    end
    packed = StringIO.new("".b)
    Zlib::GzipWriter.wrap(packed) do |gzip|
      gzip.mtime = 0
      gzip.write(buffer.string)
    end
    archive = packed.string
    package = Digest::SHA256.hexdigest(archive)
    directory = File.join(@extension_root, "packages", MODULE_ID, version, package)
    files.each do |path, bytes|
      target = File.join(directory, "files", path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, bytes)
      File.chmod(0o644, target)
    end
    write_json(File.join(directory, "manifest.json"), manifest)
    statement = {
      "format" => Ext::Trust::PACKAGE, "id" => MODULE_ID, "version" => version, "manifest_sha256" => Ext.digest(manifest),
      "package_sha256" => package, "size" => archive.bytesize, "sequence" => 1, "expires_at" => Time.now.to_i + 600
    }
    write_json(File.join(directory, "envelope.json"), sign_extension(statement, key))
    File.binwrite(File.join(directory, "package.tar.gz"), archive)
    [ statement.slice("id", "version", "manifest_sha256", "package_sha256").merge("entrypoint" => manifest.fetch("entrypoint"), "dependencies" => {}), directory ]
  end

  def write_json(path, document)
    File.write(path, Crypto.canonical(document))
  end

  def load_extension_set(rows, previous: Ext::Registry.empty)
    write_json(File.join(@extension_root, "engine-set.json"), {
      "format" => Ext::EngineSet::FORMAT, "site" => @extension_site.install_id, "core" => Railpress::Product::VERSION,
      "extension_api" => Railpress::Product::EXTENSION_API, "generation" => previous.generation + 1,
      "previous_generation" => previous.generation, "previous_fingerprint" => previous.fingerprint, "packages" => rows
    })
    load_extension_registry
  end

  def load_extension_registry
    Ext::Registry.new(Ext::EngineSet.load(root: @extension_root, site: @extension_site.install_id, synthetic: true), {})
  end

  def selection_for(entry, previous: Ext::Registry.empty, activation: 0, operation: "install")
    { "request_key" => SecureRandom.uuid, "operation" => operation, "module_id" => entry.id, "version" => entry.version,
      "package_sha256" => entry.package_sha256, "manifest_sha256" => entry.manifest.digest, "plan_sha256" => entry.plan_sha256,
      "engine_generation" => previous.generation, "engine_fingerprint" => previous.fingerprint, "activation_generation" => activation }
  end

  def receipt_for(request, registry, state, sequence, **overrides)
    now = Time.now.to_i
    statement = {
      "format" => Ext::Trust::RECEIPT, "id" => MODULE_ID, "request_sha256" => Extensions::Requests.request_digest(request),
      "sequence" => sequence, "issued_at" => now, "expires_at" => now + 180, "state" => state, "engine_generation" => registry.generation,
      "engine_fingerprint" => registry.fingerprint, "processes" => nil, "module_schema" => nil, "job_revision" => nil, "retention_clear" => false
    }.merge(overrides.stringify_keys)
    Crypto.canonical(sign_extension(statement, @operator_key))
  end

  def accept(request, registry, state, sequence, **overrides)
    Extensions::Requests.accept!(request_key: request.request_key, registry: registry,
      envelope: receipt_for(request, registry, state, sequence, **overrides))
  end

  def apply_extension_migrations(request, registry)
    Ext::Migrations.apply!(request: request, registry: registry, lock_path: @extension_lock)
  end

  def change_activation(registry, enabled, generation)
    Extensions::Activation.change!(actor: @owner, module_id: MODULE_ID, enabled: enabled, generation: generation, registry: registry)
  end

  def process_probe(code)
    command = <<~RUBY
      begin
        require "action_dispatch/testing/integration"
        registry = Railpress::Extensions.registry
        abort "Wrong extension site" unless Site.find_by!(singleton_key: 1).install_id == registry.site
        probe = (#{code})
        puts JSON.generate("pid" => Process.pid, "fingerprint" => registry.fingerprint, "healthy" => true, "probe" => probe)
      rescue StandardError => error
        warn error.full_message(highlight: false)
        exit 1
      end
    RUBY
    output, errors, status = Open3.capture3(extension_environment, Rails.root.join("bin/rails").to_s, "runner", "--skip-executor", command)
    assert status.success?, errors.lines.first(24).join
    JSON.parse(output.lines.last)
  end

  def native_worker_probe
    queue = File.join(@extension_root, "queue.yml")
    File.write(queue, "test:\n  workers:\n    - queues: neutral_probe\n      threads: 1\n      polling_interval: 1\n", perm: 0o600)
    message = process_probe(<<~RUBY).fetch("probe")
      begin
        job = NeutralProbe::RecordJob.new
        SolidQueue::Job.enqueue(job)
        job.provider_job_id
      end
    RUBY
    output = File.join(@extension_root, "worker-#{message}.log")
    pid = nil
    File.open(output, "w", 0o600) do |log|
      pid = Process.spawn(extension_environment, Rails.root.join("bin/jobs").to_s, "--mode", "async",
        "--skip-recurring", "--config-file", queue, out: log, err: [ :child, :out ], pgroup: true)
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
    until NativeQueueObservation.jobs([ message ]).first&.finished_at
      failed = SolidQueue::FailedExecution.uncached { SolidQueue::FailedExecution.where(job_id: message).first }
      flunk "Neutral worker job failed: #{failed.exception_class}" if failed
      flunk "Neutral worker did not complete within 25 seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    reported_pid, fingerprint = File.read(output).match(/^NEUTRAL_WORKER (\d+) ([a-f0-9]{64})$/)&.captures
    assert_equal pid, reported_pid.to_i
    assert_match(/\A[a-f0-9]{64}\z/, fingerprint)
    { "pid" => pid, "fingerprint" => fingerprint, "healthy" => true }
  ensure
    if pid
      Process.kill("TERM", -pid) rescue Errno::ESRCH
      begin
        Timeout.timeout(8) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end
    SolidQueue::Job.find_by(id: message)&.destroy! if message
  end

  def extension_environment
    { "RAILPRESS_EXTENSION_ROOT" => @extension_root, "RAILPRESS_EXTENSION_SITE" => @extension_site.install_id }
  end

  def process_evidence
    {
      "web" => process_probe("defined?(NeutralProbe::ProbesController) == 'constant'"),
      "worker" => process_probe("defined?(NeutralProbe::RecordJob) == 'constant'")
    }.transform_values do |identity|
      assert_equal !!load_extension_registry.entries[MODULE_ID], identity.fetch("probe")
      identity.except("probe")
    end
  end

  def cleanup_extension_site
    return unless @extension_config && @extension_site

    Railpress::TestDatabase.verify!(@extension_config)
    if @w01_owns_scratch
      connection = ActiveRecord::Base.connection
      SCRATCH_TABLES.each { |table| connection.drop_table(table, if_exists: true) }
    end
    TestSchemaIntegrity.verify!
    requests = ExtensionInstallRequest.where(site: @extension_site)
    PlatformState.where(scope_name: Extensions::CatalogHandoff::REQUEST_SCOPE, key_name: requests.select(:request_key)).delete_all
    [ ExtensionMigrationRecord, ExtensionInstallRequest, ExtensionInstallation ].each do |model|
      model.where(site: @extension_site).delete_all
    end
  end
end
