require "json"
require "digest"
require "securerandom"
require "fileutils"

# Observes the calls already made by the test; no added clock/DB reads in a
# refresh. Raw clock/cache snapshots remain private; exported observations omit
# payloads, arbitrary error text, raw bindings, validators and credentials.
class NewsTrace
  LIMIT = 4096
  def initialize(test, clock, client, refresh)
    @test, @client = test, client
    @events, @clocks, @restore = [], {}, []
    @mutex = Mutex.new
    @last_row = nil
    watch_clock(clock, "default")
    watch_refresh(refresh)
    wrap(client, :get) do |original, *args, **options|
      record("request", "etag" => validator(options[:etag]), "modified" => validator(options[:last_modified]))
      result = original.call(*args, **options)
      record("response", "status" => result.status)
      result
    end
    wrap(OfficialNews::Cache, :valid?) do |original, checked_clock, value, ttl|
      result = original.call(checked_clock, value, ttl)
      if @clocks.key?(checked_clock.object_id)
        record("cache_gate", "clock" => @clocks[checked_clock.object_id][:label], "ttl" => ttl,
          "binding" => binding(value), "accepted" => result)
      end
      result
    end
  end
  def watch_clock(clock, label)
    return if @clocks.key?(clock.object_id)
    @clocks[clock.object_id] = { clock: clock, label: label }
    wrap(clock, :sample) do |original|
      result = original.call
      record("clock", "clock" => label, "wall" => result["wall"], "elapsed" => result["elapsed"],
        "generation" => result["generation"], "segments" => result["segments"], "anomaly" => result["anomaly"],
        "domain_sha256" => digest(result["domain"]), "epoch_sha256" => digest(result["epoch"]))
      result
    end
  end
  def watch_refresh(refresh)
    wrap(refresh, :call) do |original, *args|
      record("refresh_start", "generation" => args[1])
      result = original.call(*args)
      record("refresh_end", "row" => row_state(@last_row))
      result
    end
    wrap(refresh, :eligible?) do |original, row, generation|
      @last_row = row
      result = original.call(row, generation)
      record("eligibility", "accepted" => result, "row" => row_state(row))
      result
    end
  end
  def mark(label, row = nil)
    record("step", "label" => label, "row" => row_state(row || @last_row))
  end
  def finish!(private_root, row)
    QualificationEvidence.root!(private_root)
    id = SecureRandom.uuid
    base = Rails.root.join(".local/state/news-traces", ENV.fetch("RAILPRESS_TEST_ENGINE"))
    FileUtils.mkdir_p(base, mode: 0o700)
    directory = base.join(id);Dir.mkdir(directory, 0o700)
    raw = {}
    @clocks.values.each_with_index do |entry, number|
      root = File.expand_path(entry[:clock].instance_variable_get(:@root))
      raise "Unsafe news clock trace root" unless root == private_root || root.start_with?(private_root + "/")
      path = File.join(root, "security-clock.json")
      next unless File.exist?(path) || File.symlink?(path)
      stat = File.lstat(path)
      raise "Unsafe news clock trace file" unless !stat.symlink? && stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= 65_536
      bytes = File.binread(path)
      name = "clock-#{number}.private.json"
      write(directory.join(name), bytes)
      raw[name] = { "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize, "clock" => entry[:label] }
    end
    fresh = row && row.class.uncached { row.class.find_by(id: row.id) }
    if fresh
      bytes = JSON.generate(fresh.attributes)
      raise "News cache trace capacity" if bytes.bytesize > 4 * 1024**2
      write(directory.join("cache-row.private.json"), bytes)
      raw["cache-row.private.json"] = { "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize }
    end
    value = { "format" => "railpress.news-test-trace.v1", "test" => @test.name, "engine" => ENV.fetch("RAILPRESS_TEST_ENGINE"),
      "failed_before_teardown" => !@test.passed?, "events" => @events, "loaded_row_before_cleanup" => row_state(row), "final_row" => row_state(fresh),
      "cache_snapshot_read" => "uncached after sequence, before cleanup",
      "payload_fingerprint" => "SHA256 of database-decoded JSON serialization; logical equality tested separately",
      "client_calls" => @client.calls, "request_validators" => @client.headers.map { |headers| { "etag" => validator(headers[:etag]), "modified" => validator(headers[:last_modified]) } },
      "raw_private_files" => raw, "private_directory" => directory.to_s,
      "scope" => "existing calls observed; raw snapshots captured before identity SQL/root cleanup; no independent host-time or original-incident attribution" }
    bytes = JSON.pretty_generate(value)
    write(directory.join("trace.json"), bytes)
    milestone = ENV["RAILPRESS_EVIDENCE_MILESTONE"]
    if milestone
      raise "Unsafe news evidence label" unless milestone.match?(/\A[A-Za-z0-9_-]+\z/)
      dest = Rails.root.join("docs/evidence", milestone);FileUtils.mkdir_p(dest)
      write(dest.join("news-trace-#{id}.json"), bytes)
    end
    value
  ensure
    @restore.reverse_each(&:call)
  end
  def held?
    @mutex.synchronize { @events.any? { |event| event["kind"] == "clock" && event["anomaly"] } }
  end
  def dispatches_authorized?
    @mutex.synchronize do
      eligible = false
      @events.all? do |event|
        eligible = event["accepted"] if event["kind"] == "eligibility"
        event["kind"] != "request" || eligible == true
      end
    end
  end
  private
  def wrap(target, name, &callback)
    original = target.method(name)
    was_private = target.private_methods.include?(name)
    target.define_singleton_method(name) { |*args, **options, &block| callback.call(original, *args, **options, &block) }
    target.singleton_class.send(:private, name) if was_private
    @restore << -> { target.define_singleton_method(name, original);target.singleton_class.send(:private, name) if was_private }
  end
  def record(kind, fields)
    @mutex.synchronize do
      raise "News trace capacity" if @events.length >= LIMIT
      @events << { "sequence" => @events.length + 1, "kind" => kind, "monotonic" => Process.clock_gettime(Process::CLOCK_MONOTONIC) }.merge(fields)
    end
  end
  def digest(value) = value && Digest::SHA256.hexdigest(value.to_s)
  def validator(value) = { "present" => !value.nil?, "bytes" => value&.bytesize, "sha256" => digest(value) }
  def binding(value)
    return { "present" => false } unless value.is_a?(Hash)
    value.slice("version", "generation", "issued_elapsed", "deadline", "wall_deadline").merge(
      "present" => true, "domain_sha256" => digest(value["domain"]), "epoch_sha256" => digest(value["epoch"]))
  end
  def row_state(row)
    return nil unless row
    { "enabled" => row.enabled, "generation" => row.generation, "lock_version" => row.lock_version,
      "payload_sha256" => row.payload && Digest::SHA256.hexdigest(JSON.generate(row.payload)),
      "etag" => validator(row.etag), "last_error" => row.last_error,
      "lease_present" => !row.lease_key.nil?, "wait" => binding(row.wait_binding), "lease" => binding(row.lease_binding),
      "fresh" => binding(row.fresh_binding), "retention" => binding(row.retention_binding) }
  end
  def write(path, bytes)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(bytes);file.flush;file.fsync }
  end
end
