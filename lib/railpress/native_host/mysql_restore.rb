# frozen_string_literal: true

module Railpress
  module NativeHost
    # MySQL DDL is not transactional. Bind cancellation to the CLI's exact
    # connection; a reaped client or an acknowledged KILL is not quiescence.
    class MysqlRestore
      class CleanupFailed < Error
        attr_reader :primary_error
        def initialize(primary, cleanup)
          @primary_error = primary && { "class" => primary.class.name, "code" => RestoreJournal.code(primary) }
          super(RestoreJournal.code(cleanup))
        end
      end
      def initialize(database, config)
        @database, @config = database, config
      end
      def run!(id, target, env, args, snapshot)
        NativeHost.uuid!(id)
        log = @config.path("logs", "restore-#{id}-#{SecureRandom.uuid}.log")
        identity_file = log + ".session"
        input = log + ".input.private"
        marker = @config.path("run", "mysql-restore-unsafe.json")
        raise Error, "mysql_restore_not_quiescent" if File.exist?(marker)
        @database.connection do |control, engine|
          raise Error, "database_engine" unless engine == "mysql2"
          File.open(marker, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
            file.write(Releases.canonical({ "state" => "UNVERIFIED", "operation" => id }))
            file.flush
            file.fsync
          end
          primary = nil
          begin
            File.open(input, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
              file.write("SELECT CONNECTION_ID();\n")
              File.open(snapshot, File::RDONLY | File::NOFOLLOW) { |source| IO.copy_stream(source, file) }
            end
            argv = [ @config.data["db_tools"]["client"], *args, "--batch", "--skip-column-names", "--unbuffered",
              "--skip-reconnect", target.fetch("database") ]
            # INT can continue the batch after interrupting a statement. Stop
            # input with TERM and verify server absence independently below.
            Commands.run(argv, env: env, input: input, output: identity_file, log: log, seconds: 30, timeout_signal: "TERM")
          rescue StandardError => error
            primary = error
            raise
          ensure
            begin
              verify_quiescence!(control, target, identity_file, marker, log, primary: primary)
            rescue StandardError => cleanup
              raise CleanupFailed.new(primary, cleanup), cause: primary || cleanup
            end
            File.unlink(input) if File.file?(input) && !File.symlink?(input)
          end
        end
      end
      def verify_quiescence!(control, target, identity_file, marker, log, primary: nil)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        deadline = started + 3
        original_marker = F.read(marker, maximum: 8192)
        id, cancelled, absent = nil, false, false
        line = File.open(identity_file, File::RDONLY | File::NOFOLLOW) { |file| file.gets(32) }
        raise Error, "mysql_restore_session_unverified" unless line&.match?(/\A[1-9][0-9]{0,19}\n\z/)
        id = Integer(line, 10)
        loop do
          cleanup_budget!(deadline)
          row = control.query("SELECT ID,USER,DB FROM information_schema.PROCESSLIST WHERE ID=#{id}").first
          absent = row.nil?
          cleanup_budget!(deadline)
          break if absent
          raise Error, "mysql_restore_session_ownership" unless row["USER"] == target.fetch("username") && row["DB"] == target.fetch("database")
          unless cancelled
            cleanup_budget!(deadline)
            control.query("KILL CONNECTION #{id}")
            cancelled = true
            cleanup_budget!(deadline)
          end
          sleep 0.02
        end
        cleanup_receipt!(log, started, id, cancelled, absent, primary, "VERIFIED")
        cleanup_budget!(deadline)
        File.unlink(marker)
        cleanup_budget!(deadline)
        true
      rescue StandardError => error
        # Blocking native IO/fsync may return after the decision budget. Late
        # absence is useful evidence, never successful cleanup within the bound.
        F.atomic(marker, original_marker) if original_marker && !File.exist?(marker)
        code = error.is_a?(Error) ? RestoreJournal.code(error) : "mysql_restore_session_unverified"
        cleanup_receipt!(log, started, id, cancelled, absent, primary, "FAILED", code, error.class.name)
        raise Error, code
      end
      private
      def cleanup_budget!(deadline)
        raise Error, "mysql_restore_cleanup_deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      end
      def cleanup_receipt!(log, started, id, cancelled, absent, primary, state, code = nil, error_class = nil)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        F.atomic(log + ".quiescence.json", Releases.canonical({ "state" => state, "connection_id" => id,
          "owned_server_cancel_requested" => cancelled, "server_session_absent" => absent,
          "decision_budget_seconds" => 3, "elapsed_seconds" => elapsed, "over_budget" => elapsed >= 3,
          "error" => code, "error_class" => error_class,
          "primary_error" => primary && { "class" => primary.class.name, "code" => RestoreJournal.code(primary) } }))
      end
    end
  end
end
