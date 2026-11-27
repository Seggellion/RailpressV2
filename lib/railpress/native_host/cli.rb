# frozen_string_literal: true

module Railpress
  module NativeHost
    class Cli
      COMMANDS = %w[supervise status authorize initialize preflight stage prepare-stage promote revert backup restore recovery-point module-apply].freeze
      def self.parse(argv)
        args = argv.dup
        command = args.shift
        raise Error, "native_cli_usage" unless COMMANDS.include?(command)
        case command
        when "supervise"
          raise Error, "native_cli_usage" unless args.empty? || args == [ "--once" ]
          { command: command, once: !args.empty? }
        when "status"
          raise Error, "native_cli_usage" unless args.empty? || args == [ "--publish" ]
          { command: command, publish: !args.empty? }
        when "authorize"
          operation, id, digest, flag, confirmation, *tail = args
          raise Error, "native_cli_usage" unless OPERATIONS.include?(operation) && flag == "--confirm-deployment"
          NativeHost.uuid!(id)
          NativeHost.uuid!(confirmation)
          Releases.identity!(digest)
          snapshot, loss = nil
          if operation == "restore"
            raise Error, "native_cli_usage" unless tail.length == 4 && tail[0] == "--snapshot" && tail[2] == "--accept-loss"
            snapshot, loss = tail[1], tail[3]
            NativeHost.uuid!(snapshot)
            Releases.identity!(loss)
          else
            raise Error, "native_cli_usage" unless tail.empty?
          end
          { command: command, operation: operation, id: id, release_id: digest, confirmation: confirmation,
            snapshot_id: snapshot, loss_fingerprint: loss }
        when "module-apply"
          id, option, confirmation = args
          raise Error, "native_cli_usage" unless args.length == 3 && option == "--confirm-deployment"
          { command: command, id: NativeHost.uuid!(id), confirmation: NativeHost.uuid!(confirmation) }
        when "recovery-point"
          raise Error, "native_cli_usage" unless args.empty?
          { command: command }
        else
          id = args.shift
          NativeHost.uuid!(id)
          raise Error, "native_cli_usage" unless args.empty? || (args == [ "--dry-run" ] && !%w[stage prepare-stage].include?(command))
          { command: command, id: id, dry_run: !args.empty? }
        end
      end
      def self.run(argv, output: $stdout, error: $stderr)
        parsed = parse(argv)
        attempts = 0
        begin
          new(parsed).run(output)
        rescue Error => failure
          # A supervisor observation may briefly own the same operation lock.
          # Retry this unchanged command only before lock acquisition succeeds.
          raise unless failure.message == "operation_busy" && attempts < 3
          sleep(0.05 * (2**attempts))
          attempts += 1
          retry
        end
      rescue StandardError => failure
        code = failure.is_a?(Error) && failure.message.match?(/\A[a-z_]{1,100}\z/) ? failure.message : "native_cli_refused"
        error.puts "Native release command refused (#{code}). Inspect the private operator journal. No production operation is authorized by this profile."
        2
      end
      def initialize(parsed)
        @parsed = parsed
        @config = Config.new(ENV.fetch("RAILPRESS_NATIVE_HOST_ROOT"))
        @database = Database.new(@config)
        @approving = parsed[:command] == "authorize"
        @host = Host.new(@config, authorize: method(:authorize_request!), progress: method(:deliver_receipt!))
      end
      def run(output)
        case @parsed[:command]
        when "supervise"
          Supervisor.new(@host).run(once: @parsed[:once])
          result = { "supervisor_stopped" => true, "active_services_left_running" => true }
        when "status"
          result = @host.status
          if @parsed[:publish]
            @host.store.transaction do |state|
              @host.runtime.recover_services!(state)
              @host.publish!(state)
            end
          end
        when "authorize"
          result = @host.approve!(**@parsed.slice(:operation, :id, :release_id, :confirmation, :snapshot_id, :loss_fingerprint))
        when "module-apply"
          result = apply_module!
        when "recovery-point"
          status = @host.status
          raise Error, "active_release_unknown" if status["reconciliation_required"] || status["maintenance"]
          report = @host.runtime.probe.health
          result = { "active_release" => report["release_id"], "installation_id" => report["installation_id"],
            "accept_loss_fingerprint" => Digest::SHA256.hexdigest(Releases.canonical(report.fetch("business_fingerprints"))),
            "warning" => "Restoration discards later writes after the specifically selected recovery point and revokes credentials." }
        when "stage", "prepare-stage"
          stage_command = @parsed[:command] == "stage" ? "process" : "prepare"
          root = File.expand_path("../../..", __dir__)
          log = @config.path("logs", "legacy-stage-#{SecureRandom.uuid}.log")
          Commands.run([ @config.data["ruby_binary"], File.join(root, "bin/railpress-release"), stage_command, @parsed[:id] ],
            env: operator_environment.merge("RAILPRESS_RELEASE_OPERATOR_ROOT" => @config.root), chdir: root, log: log)
          result = Releases.parse(F.read(log, maximum: 131_072).strip, limit: 131_072)
        else
          journal = NativeHost.load_document(@config.path("host-journal.json"), maximum: 2_097_152)
          request = journal.fetch("operations").fetch(@parsed[:id])
          raise Error, "operator_operation" unless request["operation"] == @parsed[:command]
          result = @parsed[:dry_run] ? @host.dry_run(@parsed[:id]) : @host.perform(@parsed[:id])
          # Preflight failures may occur before any progress callback. Deliver
          # the signed final failure as well as successful phase receipts.
          deliver_receipt!(result) unless @parsed[:dry_run]
        end
        output.puts JSON.pretty_generate(result)
        result.is_a?(Hash) && result.dig("statement", "error") ? 2 : 0
      end
      def apply_module!
        unless %w[w03_bridge w04_recruitment w04_recruitment_final].include?(@config.data["test_database_profile"]) && @parsed[:confirmation] == @config.data["deployment_id"]
          raise Error, "module_native_profile"
        end
        state = NativeHost.load_document(@config.path("host-journal.json"), maximum: 2_097_152)
        id = Releases.identity!(state["active"])
        slot = state.fetch("services").fetch(id).fetch("slot")
        helper = File.join(@config.release(id), "bin", "railpress-native-module")
        manifest, = Plan.new(@config).load!(id, trust: @host.trust, trust_state: state)
        Plan.new(@config).tree!(id, manifest)
        environment = @config.runtime_environment(id, slot: slot).merge("RAILPRESS_NATIVE_HOST_ROOT" => @config.root)
        log = @config.path("logs", "module-#{@parsed[:id]}-#{SecureRandom.uuid}.log")
        Commands.run([ @config.data["ruby_binary"], helper, @parsed[:id], @parsed[:confirmation] ],
          env: environment, chdir: @config.release(id), log: log)
        Releases.parse(F.read(log, maximum: 65_536).lines.last.to_s, limit: 65_536)
      end

      def authorize_request!(request)
        @database.assert_installation! unless request["operation"] == "restore"
        id = NativeHost.uuid!(request["id"])
        rows = @database.query("SELECT * FROM release_requests WHERE request_key='#{id}'")
        if rows.empty?
          raise Error, "owner_request_missing" unless @approving || request["origin"] == "native"
          request["origin"] = "native"
          return
        end
        row = rows.first
        raise Error, "owner_request_identity" unless row["release_digest"] == request["release_id"] && row["operation"] == request["operation"] &&
          !%w[initialize backup restore].include?(row["operation"])
        actor_id = Integer(row["actor_id"])
        actor = @database.query("SELECT id, role, auth_version FROM users WHERE id=#{actor_id}").first
        site = @database.query("SELECT id, owner_id, install_id FROM sites").first
        raise Error, "owner_authorization_changed" unless actor && site && actor["role"] == "owner" &&
          Integer(actor["auth_version"]) == Integer(row["actor_auth_version"]) && Integer(site["owner_id"]) == actor_id &&
          Integer(site["id"]) == Integer(row["site_id"]) && site["install_id"] == @config.data["install_id"]
        if request["origin"] == "owner"
          raise Error, "owner_authorization_changed" unless request["actor_id"] == actor_id && request["actor_auth_version"] == Integer(row["actor_auth_version"])
        elsif @approving
          request["origin"], request["actor_id"], request["actor_auth_version"] = "owner", actor_id, Integer(row["actor_auth_version"])
        else
          raise Error, "owner_request_identity"
        end
      end
      def deliver_receipt!(receipt)
        id = NativeHost.uuid!(receipt.dig("statement", "request_id"))
        rows = @database.query("SELECT request_key FROM release_requests WHERE request_key='#{id}'")
        return if rows.empty?
        path = @config.path("run", "#{id}-result.json")
        F.atomic(path, Releases.canonical(receipt))
        root = File.expand_path("../../..", __dir__)
        Commands.run([ @config.data["ruby_binary"], File.join(root, "bin/railpress-native-bridge"), id ],
          env: operator_environment, chdir: root, log: @config.path("logs", "bridge-#{id}-#{SecureRandom.uuid}.log"))
      end
      def operator_environment
        root = File.expand_path("../../..", __dir__)
        @config.app_environment.merge("PATH" => File.dirname(@config.data["ruby_binary"]) + ":/usr/bin:/bin", "HOME" => ENV.fetch("HOME"),
          "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "DISABLE_BOOTSNAP" => "1",
          "RAILPRESS_NATIVE_HOST_ROOT" => @config.root, "RAILPRESS_DEPLOYMENT_ID" => @config.data["deployment_id"])
      end
    end
  end
end
