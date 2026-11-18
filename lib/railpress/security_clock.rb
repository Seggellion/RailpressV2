# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "tempfile"

module Railpress
  # One private authority shared by processes in a qualified Linux boot/time domain.
  # Observed wall excursions survive SQL rollback. No application wall clock is replaced.
  class SecurityClock
    class Unavailable < StandardError; end
    HISTORY = 128
    DISCONTINUITY = 0.5
    def self.elapsed
      raise Unavailable unless Process.const_defined?(:CLOCK_BOOTTIME)
      Process.clock_gettime(Process::CLOCK_BOOTTIME)
    end
    def self.boot_domain
      boot = File.read("/proc/sys/kernel/random/boot_id").strip
      namespace = File.readlink("/proc/self/ns/time")
      raise Unavailable unless boot.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/) && namespace.match?(/\Atime:\[\d+\]\z/)
      boot + ":" + namespace
    end

    def self.for_application
      new(BootstrapState.for_application.root)
    end

    def initialize(root, elapsed: nil, domain: nil)
      @root = root.to_s
      @elapsed = elapsed || -> { self.class.elapsed }
      @domain = domain || -> { self.class.boot_domain }
    end

    def sample
      synchronize do |document|
        wall = Time.now.to_f
        ticks = @elapsed.call
        domain = @domain.call
        raise Unavailable unless finite?(wall) && finite?(ticks) && ticks >= 0 && domain.is_a?(String) && domain.bytesize.between?(1, 200)
        if document.nil? || document["domain"] != domain
          changed_domain = !document.nil?
          document = { "version" => 1, "domain" => domain, "epoch" => SecureRandom.hex(32),
            "generation" => 0, "segments" => [ { "generation" => 0, "maximum" => wall } ] }
          if changed_domain || installed_marker?
            document["anomaly"] = { "code" => changed_domain ? "clock_domain_changed" : "clock_authority_missing", "observed_at" => wall }
          end
        elsif ticks < document.fetch("elapsed")
          raise Unavailable
        else
          delta = wall - document.fetch("wall") - (ticks - document.fetch("elapsed"))
          if wall < document.fetch("wall") || delta.abs > DISCONTINUITY
            document["anomaly"] ||= { "delta" => delta, "observed_at" => wall }
          end
          if wall < document.fetch("wall")
            document["generation"] += 1
            document["segments"] << { "generation" => document["generation"], "maximum" => wall }
            document["segments"] = document["segments"].last(HISTORY)
          else
            document["segments"].last["maximum"] = [ wall, document["segments"].last["maximum"] ].max
          end
        end
        document["wall"] = wall
        document["elapsed"] = ticks
        persist(document)
        document
      end
    rescue Unavailable
      raise
    rescue SystemCallError, IOError, JSON::ParserError, KeyError, TypeError, NotImplementedError
      raise Unavailable, "Security time is unavailable; ask the operator to verify private state and sign in again.", cause: nil
    end

    def issue(ttl:, expires_at:)
      observation = sample
      remaining = [ expires_at.to_f - observation.fetch("wall"), ttl.to_f ].min
      raise Unavailable, "A fresh credential could not be issued. Verify host time and try again." unless remaining.positive? && remaining.finite?
      { "version" => 2, "domain" => observation["domain"], "epoch" => observation["epoch"],
        "generation" => observation["generation"], "issued_elapsed" => observation["elapsed"],
        "deadline" => observation["elapsed"] + remaining, "wall_deadline" => expires_at.to_f }
    end

    def valid?(binding, expires_at:, ttl:)
      observation = sample
      return false unless binding.is_a?(Hash) && binding["version"] == 2 &&
        binding["domain"] == observation["domain"] && binding["epoch"] == observation["epoch"] &&
        binding["generation"].is_a?(Integer) && binding["generation"] <= observation["generation"] &&
        observation["segments"].first["generation"] <= binding["generation"] &&
        %w[issued_elapsed deadline wall_deadline].all? { |key| finite?(binding[key]) } &&
        binding["issued_elapsed"] <= observation["elapsed"] && binding["deadline"] > observation["elapsed"] &&
        (binding["deadline"] - binding["issued_elapsed"]).between?(0, ttl.to_f + 0.000001) &&
        expires_at && expires_at.to_f <= binding["wall_deadline"] + 0.000001
      maximum = observation["segments"].select { |segment| segment["generation"] >= binding["generation"] }.map { |segment| segment["maximum"] }.max
      maximum < expires_at.to_f
    rescue Unavailable
      false
    end

    def scheduling_instant
      observation = sample
      Time.at(observation.fetch("wall")).utc unless observation["anomaly"]
    rescue Unavailable
      nil
    end

    def scheduling_allowed? = !scheduling_instant.nil?

    # Operator supplies an independently verified UTC instant; this never sets host time.
    def reconcile!(trusted_utc:, source:)
      observation = sample
      raise Unavailable, "Verify current UTC independently and supply its source." unless
        finite?(trusted_utc) && (trusted_utc - observation["wall"]).abs <= DISCONTINUITY &&
        source.is_a?(String) && source.bytesize.between?(1, 200) && !source.match?(/[\x00-\x1f]/)
      synchronize do |document|
        raise Unavailable unless document && document["epoch"] == observation["epoch"] &&
          document["elapsed"] == observation["elapsed"] && (Time.now.to_f - trusted_utc).abs <= DISCONTINUITY
        document.delete("anomaly")
        document["reconciled"] = { "at" => observation["wall"], "source" => source }
        persist(document)
      end
      true
    end

    private

    def installed_marker?
      path = File.join(@root, "setup.json")
      return false unless File.exist?(path) || File.symlink?(path)
      safe!(path)
      raise Unavailable if File.size(path) > 16_384
      marker = JSON.parse(File.read(path))
      raise Unavailable unless marker.is_a?(Hash)
      marker["status"] == "installed"
    end

    def finite?(value) = value.is_a?(Numeric) && value.finite?

    def synchronize
      raise Unavailable unless File.absolute_path(@root) == @root
      FileUtils.mkdir_p(@root, mode: 0o700)
      safe!(@root, directory: true)
      lock_path = File.join(@root, "security-clock.lock")
      safe!(lock_path) if File.exist?(lock_path) || File.symlink?(lock_path)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        path = File.join(@root, "security-clock.json")
        document = nil
        if File.exist?(path) || File.symlink?(path)
          safe!(path)
          raise Unavailable if File.size(path) > 64 * 1024
          document = JSON.parse(File.read(path))
          raise Unavailable unless valid_document?(document)
        end
        yield document
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def valid_document?(document)
      document.is_a?(Hash) && document["version"] == 1 && document["domain"].is_a?(String) &&
        document["epoch"].is_a?(String) && document["epoch"].match?(/\A[0-9a-f]{64}\z/) &&
        document["generation"].is_a?(Integer) && document["generation"] >= 0 &&
        finite?(document["wall"]) && finite?(document["elapsed"]) &&
        document["segments"].is_a?(Array) && document["segments"].length.between?(1, HISTORY) &&
        document["segments"].each_with_index.all? do |segment, index|
          segment.is_a?(Hash) && segment["generation"] == document["generation"] - document["segments"].length + index + 1 && finite?(segment["maximum"])
        end
    end

    def safe!(path, directory: false)
      stat = File.lstat(path)
      raise Unavailable unless !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero? &&
        (directory ? stat.directory? : stat.file?)
    end

    def persist(document)
      Tempfile.create([ "security-clock-", ".json" ], @root) do |file|
        file.write(JSON.generate(document))
        file.flush
        file.fsync
        File.rename(file.path, File.join(@root, "security-clock.json"))
      end
      File.open(@root, File::RDONLY) { |directory| directory.fsync }
    end
  end
end
