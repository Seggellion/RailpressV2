# frozen_string_literal: true

module Railpress
  module NativeHost
    # Existing M11/M12 commands composed by a separately provisioned native
    # service. The web process never imports this driver or reads private keys.
    class CombinedDriver
      def initialize(config)
        @config = config
        consent = NativeHost.load_document(config.path("combined-policy.json"), maximum: 4096)
        Releases.keys!(consent, %w[format deployment_id owner_request_approval external_time_adapter_ready])
        raise Error, "combined_adapter_unconfigured" unless consent == { "format" => "railpress.combined-policy.v1", "deployment_id" => config.data["deployment_id"],
          "owner_request_approval" => true, "external_time_adapter_ready" => true }
        @signer = OpenSSL::PKey.read(F.read(config.path("status.key"), maximum: 1024))
        @clock = SecurityClock.new(config.path("clock"))
      end
      def request(id)
        NativeHost.uuid!(id)
        @config.database!
        row = ReleaseRequest.find_by!(request_key: id, operation: "promote")
        plan = ::Releases::Combined.selection(row)
        ::Releases::Combined.validate!(row, plan, theme_unchanged: !plan["result"])
        row
      end
      def components(row)
        staging = Releases::Operator.new(root: @config.root, context: ::Releases::Context.current, clock: @clock, signer: @signer)
        host = Host.new(@config, clock: @clock, authorize: ->(operation) {
          raise Error, "combined_request_identity" unless operation["id"] == row.request_key && operation["release_id"] == row.release_digest && operation["operation"] == "promote"
          ::Releases::Combined.validate!(row.reload, ::Releases::Combined.selection(row))
        })
        [ staging, host ]
      end
      def directory(id)
        parent = @config.path("combined-admissions")
        Dir.mkdir(parent, 0o700) unless File.exist?(parent)
        F.directory!(parent, private: true)
        path = File.join(parent, id)
        Dir.mkdir(path, 0o700) unless File.exist?(path)
        F.directory!(path, private: true)
      end
      def prepare(id)
        row = request(id)
        ::Releases::GithubInbox.import!(release_id: row.release_digest, root: @config.root) unless File.exist?(@config.path("inbox", row.release_digest))
        staging, host = components(row)
        staging.inspect(request_id: id, release_id: row.release_digest)
        staged_time = staging.challenge(request_id: id)
        native_time = host.approve!(operation: "promote", id: id, release_id: row.release_digest, confirmation: @config.data["deployment_id"])
        document = { "format" => "railpress.combined-challenges.v1", "request_id" => id, "release_id" => row.release_digest,
          "stage" => staged_time, "promote" => native_time.fetch("challenge") }
        path = File.join(directory(id), "challenges.json")
        raise Error, "combined_challenge_exists" if File.exist?(path)
        F.atomic(path, Releases.canonical(document))
        { "state" => "AWAITING TRUSTED TIME", "request_id" => id, "host_changed" => false }
      end
      def process(id)
        row = request(id)
        return ::Releases::Combined.result(row) if ::Releases::Combined.selection(row)["result"]
        staging, host = components(row)
        admission = directory(id)
        load_time = ->(phase) {
          bytes = F.read(File.join(admission, "#{phase}-utc.json"), maximum: 8192)
          F.atomic(@config.path("receipts", "#{id}.json"), bytes)
        }
        operator = ::Releases::CombinedOperator.new(staging: staging, host: host,
          prepare_stage: ->(_staging, _row) { load_time.call("stage") },
          approve_promote: ->(_host, _row) { load_time.call("promote") }, signer: @signer, lock_root: @config.root,
          health: ->(digest) { status = host.status; status["journal_active"] == digest && status["services_healthy"] && !status["reconciliation_required"] && !status["maintenance"] })
        operator.perform(row)
      end
      def publish
        host = Host.new(@config)
        backup_verified = false
        host.store.transaction do |state|
          begin
            policy = host.trust
            policy.apply!(state)
            host.snapshot_ready!(state, policy)
            backup_verified = true
          rescue StandardError
            backup_verified = false
          end
          host.publish!(state)
        end
        path = @config.app_environment.fetch("RAILPRESS_NATIVE_PUBLIC_STATUS")
        envelope = NativeHost.load_document(path, maximum: 65_536)
        statement = envelope.fetch("statement")
        ready = backup_verified && statement["services_healthy"] && !statement["reconciliation_required"] && statement["restore_drill_completed"] && statement["snapshot_id"] && statement["capabilities"].include?("promote")
        statement = statement.merge("combined_protocol" => ::Releases::Combined::PROTOCOL, "combined_ready" => !!ready, "backup_verified" => backup_verified)
        F.atomic(path, Releases.canonical(NativeHost.sign(statement, @signer)), mode: 0o444)
        { "combined_ready" => !!ready, "scope" => "isolated-synthetic-nginx-v1", "production_qualified" => false }
      end
      def sweep
        publish
        ReleaseRequest.where(operation: "promote").order(id: :asc).limit(64).each do |row|
          plan = ::Releases::Combined.selection(row)
          next unless plan["format"] == ::Releases::Combined::PROTOCOL && !plan["result"]
          admission = directory(row.request_key)
          if !File.exist?(File.join(admission, "challenges.json"))
            prepare(row.request_key)
          elsif %w[stage promote].all? { |phase| File.file?(File.join(admission, "#{phase}-utc.json")) }
            process(row.request_key)
          end
        end
        { "scanned" => true, "automatic_database_restore" => false }
      end
    end
  end
end
