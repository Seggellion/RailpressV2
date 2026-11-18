# frozen_string_literal: true

require "json"
require "digest"
require "pathname"
require "open3"
require "securerandom"
require "fileutils"
require_relative "harness/templates"
require_relative "test_database"

module Railpress
  module Harness
    VERSION = 1
    class Refused < StandardError; end
    class CLI
      LIMIT = 256 * 1024
      FEATURE = /\A[a-z][a-z0-9]*(?:_[a-z][a-z0-9]*)*\z/
      RESERVED = %w[admin auth setup seo security security_clock identity member membership release releases core railpress].freeze
      SECRET = /-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----\s+[A-Za-z0-9+\/=\r\n]{64,}|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bgh[pousr]_[A-Za-z0-9]{30,}\b|\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}\b/

      def initialize(root, out: $stdout, err: $stderr)
        @root = Pathname(root).realpath
        @out, @err = out, err
      end

      def run(arguments)
        args = arguments.dup
        environment!
        command = args.shift
        case command
        when "doctor"
          raise Refused, "doctor takes no arguments" unless args.empty?
          source = fingerprint
          emit(format: "railpress.harness.doctor.v1", ruby: RUBY_VERSION, source: source, database: "NOT CONNECTED", providers: "NOT INVOKED", state_written: false, native_setup: "docs/harness/FEATURE_PLAYBOOK.md")
        when "plan"
          feature = feature!(args.shift)
          raise Refused, "plan takes only a feature name" unless args.empty?
          emit(plan(feature))
        when "scaffold"
          feature = feature!(args.shift)
          options = options!(args, %w[--review --confirm-development --resume], values: %w[--review])
          raise Refused, "explicit development confirmation required" unless options["--confirm-development"]
          scaffold(feature, options)
        when "verify"
          options = options!(args, %w[--engine --suite --feature --confirm-synthetic], values: %w[--engine --suite --feature])
          verify(options)
        when "report"
          raise Refused, "report takes no arguments" unless args.empty?
          report
        else
          raise Refused, "usage: doctor | plan FEATURE | scaffold FEATURE --review SHA --confirm-development [--resume] | verify --engine postgresql|mysql2 --confirm-synthetic [--suite tests|example|quality] [--feature FEATURE] | report"
        end
        0
      rescue Refused, JSON::ParserError, SystemCallError => error
        @err.puts "REFUSED: #{error.is_a?(Refused) ? error.message : error.class.name}; no authorization or release claim granted"
        1
      end

      def environment!
        raise Refused, "production or connection overrides prohibited (values redacted)" if ENV["RAILS_ENV"] && ENV["RAILS_ENV"] != "test"
        raise Refused, "production or connection overrides prohibited (values redacted)" if ENV.key?("DATABASE_URL") || ENV.keys.any? { |key| key.start_with?("RAILPRESS_DB_") }
        raise Refused, "Git environment overrides prohibited" if ENV.keys.any? { |key| %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT].include?(key) }
        %w[AGENTS.md Gemfile.lock lib/railpress/product.rb].each { |name| safe_file!(name) }
        raise Refused, "Railpress developer checkout required" unless git("rev-parse", "--show-toplevel").strip == @root.to_s
      end

      def feature!(value)
        raise Refused, "feature must have lowercase ASCII letter-led segments, at most 40 characters, outside reserved core names" unless value.is_a?(String) && value.bytesize <= 40 && FEATURE.match?(value) && !RESERVED.include?(value)
        value
      end

      def options!(args, allowed, values:)
        options = {}
        until args.empty?
          key = args.shift
          raise Refused, "unknown or duplicate option" unless allowed.include?(key) && !options.key?(key)
          value = values.include?(key) ? args.shift : true
          raise Refused, "option value required" unless value && !value.to_s.start_with?("--")
          options[key] = value
        end
        options
      end

      def git(*args)
        output, status = Open3.capture2e({ "GIT_OPTIONAL_LOCKS" => "0", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null" }, "git", "-c", "core.fsmonitor=false", *args, chdir: @root.to_s)
        raise Refused, "read-only Git inspection failed" unless status.success?
        output
      end

      def path!(relative)
        raise Refused, "unsafe relative path" unless relative.is_a?(String) && !relative.empty? && !relative.start_with?("/") && relative.split("/").none? { |part| [ "", ".", ".." ].include?(part) } && !relative.include?("\\") && !relative.include?("\0")
        cursor = @root
        relative.split("/").each do |part|
          cursor = cursor.join(part)
          raise Refused, "symlink or foreign-owned path refused" if cursor.symlink? || (cursor.exist? && cursor.stat.uid != Process.uid)
        end
        cursor
      end

      def safe_file!(relative, private: false)
        path = path!(relative)
        raise Refused, "required regular file missing" unless path.file?
        raise Refused, "private state permissions" if private && (path.stat.mode & 0o077) != 0
        path
      end

      def fingerprint(except: [])
        names = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0").uniq.sort - except
        deleted = git("ls-files", "--deleted", "-z").split("\0")
        raise Refused, "unexpected source inventory" unless (1..10_000).cover?(names.size)
        hashes = names.map do |name|
          next [ name, "DELETED" ] if deleted.include?(name) && !path!(name).exist?
          raise Refused, "secret-bearing path refused" if /(?:\A|\/)(?:\.env[^\/]*|master\.key|credentials[^\/]*\.(?:key|json)|[^\/]+\.(?:pem|key|dump|sql))\z/.match?(name)
          file = safe_file!(name)
          if /\.(?:rb|md|yml|yaml|json|txt|js|erb)\z/.match?(name)
            raise Refused, "text source exceeds inspection bound" if file.size > 4 * 1024 * 1024
            raise Refused, "possible source secret refused (value redacted)" if SECRET.match?(file.binread.force_encoding(Encoding::BINARY))
          end
          [ name, Digest::SHA256.file(file).hexdigest ]
        end
        Digest::SHA256.hexdigest(JSON.generate(hashes))
      end

      def plan(feature)
        files = Templates.files(feature)
        document = { "format" => "railpress.harness.plan.v1", "feature" => feature, "root_binding" => Digest::SHA256.hexdigest(@root.to_s), "source" => fingerprint(except: files.keys), "policy_sha256" => Digest::SHA256.file(safe_file!("AGENTS.md")).hexdigest,
          "files" => files, "mounted_routes" => [], "migrations" => [], "permission_grants" => [], "production_authority" => false }
        document.merge("review_sha256" => Digest::SHA256.hexdigest(JSON.generate(document)))
      end

      def private_directory(relative)
        path = path!(relative)
        FileUtils.mkdir_p(path, mode: 0o700)
        raise Refused, "private state permissions" unless path.stat.uid == Process.uid && (path.stat.mode & 0o077).zero?
        path
      end

      def load_state(path)
        raise Refused, "state exceeds bound" if path.size > LIMIT
        JSON.parse(path.binread)
      end

      def write_state(path, document)
        temporary = path.dirname.join(".state-#{SecureRandom.uuid}")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(JSON.generate(document)); file.flush; file.fsync }
        File.rename(temporary, path)
      ensure
        File.unlink(temporary) if temporary && temporary.file?
      end

      def scaffold(feature, options)
        reviewed = plan(feature)
        raise Refused, "review digest does not match current plan" unless options["--review"] == reviewed.fetch("review_sha256")
        raise Refused, "development capacity below 1GiB" if available_bytes < 1024**3
        parent = private_directory(".local/harness")
        with_mutation_lock do
          raise Refused, "source changed while acquiring lock" unless plan(feature) == reviewed
          state_path = parent.join("#{feature}.json")
          state = state_path.exist? ? load_state(safe_file!(".local/harness/#{feature}.json", private: true)) : nil
          hashes = reviewed["files"].transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
          expected = { "format" => "railpress.harness.scaffold.v1", "feature" => feature, "review_sha256" => reviewed["review_sha256"], "files" => hashes }
          raise Refused, "state does not match reviewed plan" if state && expected.any? { |key, value| state[key] != value }
          existing = hashes.keys.select { |name| path!(name).exist? }
          raise Refused, "existing files require the matching owned receipt" if !state && existing.any?
          existing.each { |name| raise Refused, "generated file conflict; preserve and review" unless Digest::SHA256.file(safe_file!(name)).hexdigest == hashes[name] }
          if state && state["phase"] != "COMPLETE"
            raise Refused, "partial scaffold requires explicit --resume" unless options["--resume"]
          end
          write_state(state_path, expected.merge("phase" => "WRITING"))
          reviewed["files"].each do |name, bytes|
            path = path!(name)
            next if path.exist?
            FileUtils.mkdir_p(path.dirname)
            path!(name)
            File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o644) { |file| file.write(bytes); file.flush; file.fsync }
          end
          write_state(state_path, expected.merge("phase" => "COMPLETE"))
          emit(expected.merge("phase" => "COMPLETE", "resume_or_repeat" => !state.nil?, "warning" => "Unmounted development files only; review before integration"))
        end
      end

      def with_mutation_lock
        private_directory(".local/harness")
        lock_path = path!(".local/harness/lock")
        File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          raise Refused, "another harness mutation or verification is active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          yield
        end
      end

      def available_bytes
        [ @root.to_s, *(File.directory?("/mnt/c") ? [ "/mnt/c" ] : []) ].map do |path|
          output, status = Open3.capture2e("df", "-Pk", path)
          raise Refused, "capacity unavailable" unless status.success?
          Integer(output.lines.last.split.fetch(3)) * 1024
        end.min
      end

      def verify(options)
        with_mutation_lock { verify_locked(options) }
      end

      def verify_locked(options)
        engine = options["--engine"]
        raise Refused, "explicit synthetic engine/confirmation required" unless %w[postgresql mysql2].include?(engine) && options["--confirm-synthetic"]
        suite = options.fetch("--suite", "tests")
        raise Refused, "unknown suite" unless %w[tests example quality].include?(suite)
        feature = options["--feature"] && feature!(options["--feature"])
        raise Refused, "feature is only for example suite" if feature && suite != "example"
        source = fingerprint
        raise Refused, "test capacity below 8GiB" if available_bytes < 8 * 1024**3
        require "bundler/setup"
        target = TestDatabase.load!(root: @root, engine: engine, environment: "test", confirmed: "railpress-synthetic-only")
        identity = TestDatabase.verify!(target, environment: "test", confirmed: "railpress-synthetic-only")
        jobs = if suite == "quality"
          raise Refused, "offline advisory database missing; provision it explicitly before verification" unless path!(".local/advisories/.git").directory? && path!(".local/advisories/gems").directory?
          [ [ "bundle", "exec", "rubocop" ], [ "bundle", "exec", "brakeman", "--no-pager" ], [ "bundle", "exec", "bundler-audit", "check", "--database", ".local/advisories" ] ]
        elsif suite == "example"
          raise Refused, "example feature required" unless feature
          safe_file!("test/harness_extensions/#{feature}_test.rb")
          [ [ "bin/native_test", engine, "--confirm-synthetic", "test", "test/harness_extensions/#{feature}_test.rb" ] ]
        else
          [ [ "bin/native_test", engine, "--confirm-synthetic", "test" ], [ "bin/native_test", engine, "--confirm-synthetic", "zeitwerk:check" ] ]
        end
        folder = private_directory(".local/harness/verifications")
        id = SecureRandom.uuid
        milestone = "harness_#{id.delete('-')}"
        FileUtils.mkdir_p(path!("docs/evidence/#{milestone}"))
        receipt = { "format" => "railpress.harness.verification.v1", "id" => id, "engine" => engine, "suite" => suite, "source" => source, "identity" => identity, "commands" => [], "phase" => "RUNNING", "evidence_milestone" => milestone, "browser" => "NOT TESTED", "release_authority" => false }
        path = folder.join("#{id}.json")
        write_state(path, receipt)
        jobs.each_with_index do |argv, number|
          log = folder.join("#{id}-#{number}.log")
          result = command(argv, log, milestone: milestone)
          receipt["commands"] << { "argv" => argv, "exit" => result, "log_sha256" => Digest::SHA256.file(log).hexdigest }
          write_state(path, receipt)
          break unless result.zero?
        end
        receipt["phase"] = receipt["commands"].size == jobs.size && receipt["commands"].all? { |row| row["exit"].zero? } && fingerprint == source ? "PASS" : "FAILED_OR_SOURCE_CHANGED"
        write_state(path, receipt)
        emit(receipt)
        raise Refused, "verification did not pass; private receipt/logs retained" unless receipt["phase"] == "PASS"
      rescue TestDatabase::UnsafeTarget
        raise Refused, "synthetic database admission refused (details redacted)"
      end

      def command(argv, log, milestone: "harness_command")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        pid = nil
        reader, writer = IO.pipe
        reader.binmode; writer.binmode
        File.open(log, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
          pid = Process.spawn({ "RAILS_ENV" => "test", "RAILPRESS_EVIDENCE_MILESTONE" => milestone }, *argv, chdir: @root.to_s, in: File::NULL, out: writer, err: writer, pgroup: true)
          writer.close
          written = 0; ended = false; done = nil
          loop do
            if !ended && IO.select([ reader ], nil, nil, 0.05)
              begin
                bytes = reader.read_nonblock(16_384)
                remaining = 2 * 1024 * 1024 - written
                file.write(bytes.byteslice(0, remaining))
                file.flush
                written += bytes.bytesize
                raise Refused, "command output exceeds 2MiB; bounded private output retained" if written > 2 * 1024 * 1024
              rescue IO::WaitReadable
              rescue EOFError
                ended = true
              end
            end
            done ||= Process.waitpid2(pid, Process::WNOHANG)
            if done && ended
              pid = nil
              return done.last.exitstatus || 128 + done.last.termsig
            end
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 3600
              raise Refused, "outer verification deadline; existing application budgets unchanged"
            end
            sleep 0.02 if ended
          end
        end
      ensure
        if pid
          Process.kill("TERM", -pid) rescue Errno::ESRCH
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
          loop do
            break if Process.waitpid(pid, Process::WNOHANG)
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              Process.kill("KILL", -pid) rescue Errno::ESRCH
              Process.waitpid(pid) rescue Errno::ECHILD
              break
            end
            sleep 0.02
          rescue Errno::ECHILD
            break
          end
        end
        reader.close if reader && !reader.closed?
        writer.close if writer && !writer.closed?
      end

      def report
        source = fingerprint
        parent = path!(".local/harness")
        records = parent.directory? ? parent.glob("*.json") + parent.glob("verifications/*.json") : []
        raise Refused, "too many local receipts; review private state" if records.size > 256
        rows = records.sort.map do |path|
          relative = path.relative_path_from(@root).to_s
          row = load_state(safe_file!(relative, private: true))
          feature = nil
          raise Refused, "unknown receipt" unless %w[railpress.harness.scaffold.v1 railpress.harness.verification.v1].include?(row["format"])
          raise Refused, "unsafe receipt field" unless %w[WRITING COMPLETE RUNNING PASS FAILED_OR_SOURCE_CHANGED].include?(row["phase"])
          if row["format"] == "railpress.harness.scaffold.v1"
            feature = feature!(row["feature"])
            reviewed = plan(feature)
            hashes = reviewed["files"].transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
            current = row["review_sha256"] == reviewed["review_sha256"] && row["files"] == hashes && hashes.all? { |name, digest| path!(name).file? && Digest::SHA256.file(safe_file!(name)).hexdigest == digest }
          else
            raise Refused, "unsafe receipt engine" unless %w[postgresql mysql2].include?(row["engine"])
            current = row["source"] == source
          end
          { format: row["format"], phase: current ? row["phase"] : "STALE_OR_CONFLICT", feature: feature, engine: row["format"] == "railpress.harness.verification.v1" ? row["engine"] : nil, source_current: current }
        end
        emit(format: "railpress.harness.report.v1", receipts: rows, browser: "NOT TESTED", authority: "local diagnostic only; not a signed attestation or release approval")
      end

      def emit(value)
        @out.puts JSON.pretty_generate(value)
      end
    end
  end
end
