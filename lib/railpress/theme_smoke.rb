require "timeout"
require "tmpdir"
require "rbconfig"
require_relative "theme_package"
require_relative "worker_process"
module Railpress
  module ThemeSmoke
    class Rejected < ThemePackage::Invalid
      attr_reader :diagnostic
      def initialize(code, status:, directory:, process: nil)
        @diagnostic = { code: code, exit_status: status&.exitstatus, signal: status&.termsig,
          stderr: File.binread(File.join(directory, "errors.log"), 16_384).to_s.dup.force_encoding("UTF-8").scrub,
          output_bytes: File.size(File.join(directory, "output.json")),
          limits: { cpu_seconds: 6, address_space_bytes: 768 * 1024 * 1024, output_bytes: 65_536, wall_seconds: 10 }, process: process }
        super(code)
      end
    end
    module_function
    def call(path, keys:, root:, work_root: nil)
      report = nil
      Dir.mktmpdir("theme-smoke-", work_root) do |directory|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        failure = nil
        key_path = File.join(directory, "keys.json")
        File.write(key_path, JSON.generate(keys), mode: "w", perm: 0o600)
        output = File.join(directory, "output.json")
        environment = { "PATH" => ENV.fetch("PATH"), "HOME" => directory, "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "RAILS_ENV" => "production", "LANG" => "C.UTF-8", "VIPS_CONCURRENCY" => "1" }
        %w[GEM_HOME GEM_PATH RUBYOPT BUNDLE_PATH BUNDLE_APP_CONFIG LD_LIBRARY_PATH RAILPRESS_WEBP_DECODER].each { |key| environment[key] = ENV[key] if ENV[key] }
        pid = Process.spawn(environment, RbConfig.ruby, File.join(root, "scripts/themes/smoke.rb"), path, key_path,
          unsetenv_others: true, chdir: root.to_s, out: output, err: File.join(directory, "errors.log"), pgroup: true,
          rlimit_cpu: 6, rlimit_as: 768 * 1024 * 1024, rlimit_fsize: 65_536)
        begin
          status = nil
          Timeout.timeout(10) { _, status = Process.wait2(pid) }
          unless status.success? && File.size(output) <= 65_536
            raise(failure = rejection("production_smoke_failed", pid, started, status, directory))
          end
          report = JSON.parse(File.read(output))
          raise ThemePackage::Invalid, "incomplete_smoke" unless report["environment"] == "production" && report["families"] == ThemePackage::FAMILIES && report["database"] == "none"
        rescue Timeout::Error
          raise(failure = rejection("production_smoke_timeout", pid, started, status, directory))
        ensure
          begin
            Process.kill("KILL", -pid)
          rescue Errno::ESRCH
            nil
          end
          begin
            _, status = Process.waitpid2(pid)
          rescue Errno::ECHILD
            nil
          end
          WorkerProcess.finish(failure.diagnostic[:process], status: status) if failure
        end
      end
      report
    end
    def rejection(code, pid, started, status, directory)
      process = WorkerProcess.capture(worker: "theme", reason: code, pid: pid, started: started, status: status,
        limits: { "wall_seconds" => 10, "cpu_seconds" => 6, "address_space_bytes" => 768 * 1024 * 1024, "output_bytes" => 65_536 })
      Rejected.new(code, status: status, directory: directory, process: process)
    end
  end
end
