# frozen_string_literal: true

require "timeout"
require "rbconfig"
require "railpress/worker_process"
module MediaLibrary
  module Processor
    class Failed < StandardError
      attr_reader :diagnostic
      def initialize(message, diagnostic: nil)
        @diagnostic = diagnostic
        super(message)
      end
    end
    WALL_SECONDS = 5
    OUTPUT_BYTES = 12 * 1024 * 1024
    module_function
    def worker_path
      Rails.root.join("bin/railpress-image").to_s
    end
    def run!(input, directory)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      failure = nil
      environment = { "PATH" => "/usr/bin:/bin", "LANG" => "C.UTF-8", "GEM_HOME" => Gem.dir,
        "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR), "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s,
        "VIPS_CONCURRENCY" => "1", "VIPS_DISC_THRESHOLD" => "32m", "MALLOC_ARENA_MAX" => "2" }
      log = File.join(directory, "worker.log")
      pid = Process.spawn(environment, RbConfig.ruby, worker_path, input, directory, unsetenv_others: true,
        rlimit_as: 768 * 1024 * 1024, rlimit_cpu: [ 4, 4 ], rlimit_fsize: OUTPUT_BYTES,
        out: log, err: [ :child, :out ], pgroup: true)
      child_pid = pid
      status = nil
      Timeout.timeout(WALL_SECONDS) { _, status = Process.wait2(pid) }
      pid = nil
      raise(failure = failed("decode", child_pid, started, status, directory)) unless status.success?
      info = JSON.parse(File.read(File.join(directory, "info.json"), 1024))
      %w[display.png thumb.png].each do |name|
        raise(failure = failed("output", child_pid, started, status, directory)) unless File.size(File.join(directory, name)).between?(1, OUTPUT_BYTES)
      end
      info
    rescue Timeout::Error
      raise(failure = failed("timeout", child_pid, started, status, directory))
    rescue JSON::ParserError, Errno::ENOENT
      raise(failure = failed("decode", child_pid, started, status, directory))
    ensure
      if pid
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        begin
          _, status = Process.waitpid2(pid)
        rescue Errno::ECHILD
          nil
        end
      end
      Railpress::WorkerProcess.finish(failure.diagnostic, status: status) if failure
    end

    def failed(reason, pid, started, status, directory)
      report = Railpress::WorkerProcess.capture(worker: "image", reason: reason, pid: pid, started: started, status: status,
        limits: { "wall_seconds" => WALL_SECONDS, "cpu_seconds" => 4, "address_space_bytes" => 768 * 1024 * 1024, "output_bytes" => OUTPUT_BYTES })
      report["file_bytes"] = %w[worker.log display.png thumb.png].to_h do |name|
        stat = File.lstat(File.join(directory, name)) rescue nil
        [ name, stat&.file? ? stat.size : nil ]
      end
      Failed.new(reason, diagnostic: report)
    end
  end
end
