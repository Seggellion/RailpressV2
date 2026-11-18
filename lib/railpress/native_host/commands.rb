# frozen_string_literal: true

module Railpress
  module NativeHost
    module Commands
      module_function
      def run(argv, env: {}, chdir: nil, log:, seconds: 30, input: nil, output: nil, timeout_signal: "TERM")
        raise Error, "native_argument_vector" unless argv.is_a?(Array) && argv.any? && argv.all? { |value| value.is_a?(String) && !value.include?("\0") }
        raise Error, "native_timeout_signal" unless %w[TERM INT].include?(timeout_signal)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, pid, timed_out, signals = nil, nil, false, []
        File.open(log, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |error|
          destination = output ? File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) : error
          source = input ? File.open(input, File::RDONLY | File::NOFOLLOW) : File::NULL
          options = { in: source, out: destination, err: error, pgroup: true, unsetenv_others: true, rlimit_fsize: 128 * 1024 * 1024 }
          options[:chdir] = chdir if chdir
          pid = Process.spawn(env, *argv, **options)
          F.atomic(log + ".result.json", Releases.canonical({ "format" => "railpress.native-command-result.v1", "state" => "RUNNING",
            "pid" => pid, "executable" => File.basename(argv.first), "started_monotonic" => start, "deadline_seconds" => seconds }))
          status = nil
          loop do
            result = Process.waitpid2(pid, Process::WNOHANG)
            if result
              status = result.last
              break
            end
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start > seconds
              timed_out = true
              signals << timeout_signal
              Process.kill(timeout_signal, -pid)
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
              loop do
                result = Process.waitpid2(pid, Process::WNOHANG)
                if result
                  status = result.last
                  break
                end
                if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                  signals << "KILL"
                  Process.kill("KILL", -pid)
                  status = Process.waitpid2(pid).last
                  break
                end
                sleep 0.02
              end
              raise Error, "native_command_deadline"
            end
            sleep 0.02
          end
          raise Error, "native_command_failed" unless status.success?
          { "exit" => status.exitstatus, "elapsed_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - start }
        ensure
          source.close if source.respond_to?(:close)
          destination.close if output && destination
        end
      rescue SystemCallError
        raise Error, "native_command_unavailable"
      ensure
        if pid
          failure = $!
          # Receipt/file failures after spawn must not abandon an executing
          # client. Preserve the original exception after bounded owned cleanup.
          unless status
            begin
              signals << timeout_signal
              Process.kill(timeout_signal, -pid)
              cleanup_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
              loop do
                found = Process.waitpid2(pid, Process::WNOHANG)
                if found
                  status = found.last
                  break
                end
                if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= cleanup_deadline
                  signals << "KILL"
                  Process.kill("KILL", -pid)
                  status = Process.waitpid2(pid).last
                  break
                end
                sleep 0.02
              end
            rescue Errno::ESRCH
              status = Process.waitpid2(pid).last
            rescue Errno::ECHILD
              # Already reaped; never signal any other PID/group.
            end
          end
          code = failure.is_a?(Error) && failure.message.match?(/\A[a-z_]{1,100}\z/) ? failure.message : (failure && "native_operation_failed")
          result = { "format" => "railpress.native-command-result.v1", "state" => code ? "FAILED" : "EXITED", "pid" => pid, "executable" => File.basename(argv.first),
            "started_monotonic" => start, "elapsed_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - start,
            "deadline_seconds" => seconds, "timed_out" => timed_out, "sent_signals" => signals,
            "exitstatus" => status&.exitstatus, "termsig" => status&.termsig, "error" => code,
            "log_bytes" => File.file?(log) ? File.size(log) : nil }
          F.atomic(log + ".result.json", Releases.canonical(result))
        end
      end
    end
  end
end
