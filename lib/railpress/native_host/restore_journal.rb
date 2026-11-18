# frozen_string_literal: true

module Railpress
  module NativeHost
    # Private diagnostic state, not completion authority or a public transcript.
    class RestoreJournal
      PHASES = %w[PREFLIGHT REPLAY_SQL SQL_COMPLETE VERIFY_INSTALLATION VERIFY_SCHEMA VERIFY_RECORDS
        VERIFY_MEDIA_REFERENCES REVOKE_CREDENTIALS VERIFY_REVOCATION RESTORE_MEDIA RESTORE_THEMES
        RESTORE_BOOTSTRAP RESTORE_ENVIRONMENT VERIFY_CLOCK VERIFY_FINAL COMPLETE].freeze
      def initialize(path, context, identity, preflight)
        @path = path
        identity_sha256 = Digest::SHA256.hexdigest(Releases.canonical(identity))
        attempt = 1
        if File.exist?(path) || File.symlink?(path)
          bytes = F.read(path, maximum: 65_536)
          previous = Releases.parse(bytes, limit: 65_536)
          raise Error, "restore_resume_context" unless context.all? { |key, value| previous[key] == value }
          raise Error, "restore_resume_context" if previous["target_identity_sha256"] && previous["target_identity_sha256"] != identity_sha256
          attempt = Integer(previous.fetch("attempt", 1)) + 1
          raise Error, "restore_retained_capacity" if attempt > 8
          old = File.join(File.dirname(path), "verification-attempt-#{attempt - 1}.json")
          raise Error, "restore_resume_context" if File.exist?(old) && F.read(old, maximum: 65_536) != bytes
          F.atomic(old, bytes) unless File.exist?(old)
        end
        @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @data = context.merge("format" => "railpress.restore-verification.v1", "target_identity_sha256" =>
          identity_sha256, "preflight" => preflight,
          "attempt" => attempt, "state" => "RESTORING", "phase" => nil, "last_completed_phase" => nil,
          "phase_sequence" => 0, "started_monotonic" => @started, "operator_pid" => Process.pid, "phases" => [])
        advance!("PREFLIGHT")
      end
      def advance!(phase)
        raise Error, "restore_phase" unless PHASES.include?(phase)
        @data["last_completed_phase"] = @data["phase"]
        @data["phase"] = phase
        @data["phase_sequence"] += 1
        @data["phases"] << { "phase" => phase, "monotonic" => Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        raise Error, "restore_phase_capacity" if @data["phases"].length > 32
        persist!
      end
      def complete!(digest)
        advance!("COMPLETE")
        @data.merge!("state" => "VERIFIED", "database_integrity_sha256" => digest)
        persist!
      end
      def fail!(error)
        @data.merge!("state" => "FAILED", "error" => self.class.code(error), "error_class" => error.class.name)
        if error.respond_to?(:primary_error)
          @data["primary_error"] = error.primary_error
        end
        state = error.sql_state if error.respond_to?(:sql_state)
        if !state && defined?(PG::Error) && error.is_a?(PG::Error) && error.result
          state = error.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
        end
        @data["sqlstate"] = state if state.is_a?(String) && state.match?(/\A[A-Z0-9]{5}\z/)
        @data["native_error_number"] = error.error_number if error.respond_to?(:error_number) && error.error_number.is_a?(Integer)
        persist!
      end
      def self.code(error)
        error.is_a?(Error) && error.message.match?(/\A[a-z_]{1,100}\z/) ? error.message : "restore_operation_failed"
      end
      private
      def persist!
        @data["elapsed_seconds"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
        F.atomic(@path, Releases.canonical(@data))
      end
    end
  end
end
