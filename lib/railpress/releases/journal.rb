# frozen_string_literal: true

module Railpress
  module Releases
    class Journal
      STATES = %w[IDLE AVAILABLE PREFLIGHT DOWNLOADING VERIFIED STAGED SCHEMA_EXPANDED WARMED READY SWITCHING VERIFYING ACTIVE FAILED_STAGED REVERT_ELIGIBILITY_CHECK PREVIOUS_ACTIVE RESTORE_REQUIRED CANCELLED].freeze
      ALLOWED = { "IDLE" => %w[AVAILABLE], "AVAILABLE" => %w[PREFLIGHT CANCELLED FAILED_STAGED],
        "PREFLIGHT" => %w[DOWNLOADING FAILED_STAGED CANCELLED], "DOWNLOADING" => %w[VERIFIED FAILED_STAGED CANCELLED],
        "VERIFIED" => %w[STAGED FAILED_STAGED CANCELLED], "STAGED" => %w[CANCELLED FAILED_STAGED],
        "FAILED_STAGED" => %w[PREFLIGHT CANCELLED], "CANCELLED" => [] }.freeze
      attr_reader :root
      def initialize(root, on_transition: nil)
        @on_transition = on_transition
        @root = Filesystem.directory!(root, private: true)
      end
      def transaction
        path = File.join(root, "journal.lock")
        Filesystem.read(path, maximum: 0) if File.exist?(path) || File.symlink?(path)
        File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          journal = File.join(root, "journal.json")
          marker = File.join(root, "initialized")
          raise Invalid, "journal_missing" if File.exist?(marker) && !File.exist?(journal)
          state = File.exist?(journal) ? Releases.parse(Filesystem.read(journal, maximum: 1_048_576)) :
            { "format" => 1, "active" => { "version" => Product::VERSION, "authority" => "running_code_only" },
              "sequence" => {}, "revoked" => [], "expired" => [], "trust_generation" => 0, "utc_max" => 0, "requests" => {}, "events" => [] }
          raise Invalid, "journal_corrupt" unless state.is_a?(Hash) && state["format"] == 1 && state["requests"].is_a?(Hash) &&
            state["sequence"].is_a?(Hash) && state["revoked"].is_a?(Array) && state["expired"].is_a?(Array) && state["events"].is_a?(Array) &&
            state["utc_max"].is_a?(Numeric) && state["trust_generation"].is_a?(Integer) && state["active"].is_a?(Hash) && state["active"].keys.sort == %w[authority version] && state["active"]["authority"] == "running_code_only" &&
            state["active"]["version"].is_a?(String) && state["active"]["version"].bytesize <= 80 && Releases::SEMVER.match?(state["active"]["version"])
          native_path = File.join(root, "host-journal.json")
          if File.exist?(native_path) || File.symlink?(native_path)
            native = Releases.parse(Filesystem.read(native_path, maximum: 2_097_152), limit: 2_097_152)
            raise Invalid, "host_journal_corrupt" unless native["format"] == "railpress.host-journal.v1"
            ReplayState.merge!(state, native)
          end
          result = yield state
          persist(state)
          Filesystem.atomic(marker, "release-journal-v1\n") unless File.exist?(marker)
          result
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
      def persist(state)
        bytes = Releases.canonical(state)
        raise Invalid, "journal_capacity" if bytes.bytesize > 1_048_576
        Filesystem.atomic(File.join(root, "journal.json"), bytes)
      end
      def transition!(state, request, next_state, detail: nil)
        raise Invalid, "m12_operation_unavailable" unless ALLOWED.fetch(request.fetch("state"), []).include?(next_state)
        request["state"] = next_state
        event = { "request" => request.fetch("id"), "state" => next_state, "detail" => detail }
        state["events"] << event
        state["events"] = state["events"].last(256)
        persist(state)
        @on_transition&.call(state, request)
      end
    end
  end
end
