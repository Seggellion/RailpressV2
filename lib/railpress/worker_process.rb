# frozen_string_literal: true

require "json"
require "etc"

module Railpress
  # Numeric, bounded evidence only. Never includes arguments, environment,
  # source/input paths, user identifiers, stdout or stderr payloads.
  module WorkerProcess
    module_function
    def capture(worker:, reason:, pid:, started:, status:, limits:)
      report = { "format" => "railpress.worker-failure.v1", "worker" => worker, "reason" => reason,
        "pid" => pid, "started_monotonic" => started, "elapsed_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        "clock" => "CLOCK_MONOTONIC", "limits" => limits, "process" => {} }
      return report if !pid || status
      fields = File.read("/proc/#{Integer(pid)}/stat", 4096).split(") ", 2).last.split
      attributes = File.read("/proc/#{Integer(pid)}/status", 16_384)
      return report unless fields[1].to_i == Process.pid && attributes[/^Uid:\s+(\d+)/, 1].to_i == Process.uid
      io = File.read("/proc/#{Integer(pid)}/io", 4096)
      report["process"] = { "state" => fields[0], "cpu_seconds" => (fields[11].to_i + fields[12].to_i).fdiv(Etc.sysconf(Etc::SC_CLK_TCK)),
        "rss_kib" => attributes[/^VmRSS:\s+(\d+)/, 1]&.to_i, "peak_virtual_kib" => attributes[/^VmPeak:\s+(\d+)/, 1]&.to_i,
        "read_bytes" => io[/^read_bytes:\s+(\d+)/, 1]&.to_i, "write_bytes" => io[/^write_bytes:\s+(\d+)/, 1]&.to_i,
        "wait_channel" => File.read("/proc/#{Integer(pid)}/wchan", 128).strip }
      report
    rescue SystemCallError, IOError, ArgumentError, NoMethodError
      report["process_unavailable"] = true
      report
    end

    def finish(report, status:)
      return unless report
      report.merge!("exit_status" => status&.exitstatus, "signal" => status&.termsig, "reaped" => !status.nil?,
        "elapsed_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - report.fetch("started_monotonic"))
      Rails.logger.warn("BOUNDED_WORKER_FAILURE #{JSON.generate(report)}") if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      report
    rescue StandardError
      report["logging_unavailable"] = true
      report
    end
  end
end
