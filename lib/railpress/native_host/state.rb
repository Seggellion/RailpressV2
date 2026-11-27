# frozen_string_literal: true

module Railpress
  module NativeHost
    class State
      attr_reader :config
      def initialize(config) = @config = config
      def transaction
        root = config.root
        lock_path = config.path("operation.lock")
        F.read(lock_path, maximum: 0) if File.exist?(lock_path) || File.symlink?(lock_path)
        File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          raise Error, "operation_busy" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          marker, journal = config.path("host-initialized"), config.path("host-journal.json")
          raise Error, "host_journal_missing" if File.exist?(marker) && !File.exist?(journal)
          document = File.exist?(journal) ? NativeHost.load_document(journal, maximum: 2_097_152) :
            { "format" => "railpress.host-journal.v1", "deployment_id" => config.data["deployment_id"],
              "generation" => 0, "active" => nil, "previous" => nil, "maintenance" => false,
              "operations" => {}, "events" => [], "releases" => {}, "snapshot" => nil,
              "trust_generation" => 0, "revoked" => [], "expired" => [], "utc_max" => 0, "sequence" => {} }
          raise Error, "host_journal_corrupt" unless document.is_a?(Hash) && document["format"] == "railpress.host-journal.v1" &&
            document["deployment_id"] == config.data["deployment_id"] && document["operations"].is_a?(Hash) &&
            document["events"].is_a?(Array) && document["releases"].is_a?(Hash) && document["generation"].is_a?(Integer) &&
            document["trust_generation"].is_a?(Integer) && document["utc_max"].is_a?(Numeric) &&
            document["revoked"].is_a?(Array) && document["expired"].is_a?(Array)
          import_staging!(document)
          result = yield document, lock
          persist(document)
          F.atomic(marker, "native-host-v1\n") unless File.exist?(marker)
          result
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
      def persist(document)
        bytes = Releases.canonical(document)
        raise Error, "host_journal_capacity" if bytes.bytesize > 2_097_152 || document["operations"].length > 256 || document["releases"].length > 32
        F.atomic(config.path("host-journal.json"), bytes)
        F.atomic(config.path("host-initialized"), "native-host-v1\n") unless File.exist?(config.path("host-initialized"))
      end
      def import_staging!(document)
        legacy_path = config.path("journal.json")
        raise Error, "staging_journal_missing" if File.exist?(config.path("initialized")) && !File.exist?(legacy_path)
        return unless File.exist?(legacy_path) || File.symlink?(legacy_path)
        legacy = NativeHost.load_document(legacy_path)
        raise Error, "staging_journal_corrupt" unless legacy["format"] == 1
        Releases::ReplayState.merge!(document, legacy)
      end
      def operation!(document, id:, operation:, release_id:)
        NativeHost.uuid!(id)
        Releases.identity!(release_id)
        raise Error, "operator_operation" unless OPERATIONS.include?(operation)
        existing = document["operations"][id]
        if existing
          raise Error, "request_conflict" unless existing.values_at("operation", "release_id") == [ operation, release_id ]
          return existing
        end
        raise Error, "host_operation_capacity" if document["operations"].length >= 256
        document["operations"][id] = { "id" => id, "operation" => operation, "release_id" => release_id, "phase" => "PREFLIGHT",
          "error" => nil, "revision" => 0, "expected_generation" => document["generation"] }
      end
      def transition!(document, request, phase, detail: nil)
        raise Error, "host_phase" unless PHASES.include?(phase)
        request["phase"] = phase
        request["revision"] += 1
        document["events"] << { "request" => request["id"], "phase" => phase, "detail" => detail, "generation" => document["generation"] }
        document["events"] = document["events"].last(512)
        persist(document)
      end
    end
  end
end
