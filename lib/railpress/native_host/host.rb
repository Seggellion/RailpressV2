# frozen_string_literal: true

module Railpress
  module NativeHost
    class Host
      attr_reader :config, :store, :runtime
      def initialize(config, clock: nil, runtime: nil, authorize: nil, progress: nil, fault: nil)
        @config = config
        @store = State.new(config)
        @runtime = runtime || Runtime.new(config, store)
        @clock = clock || SecurityClock.new(config.path("clock"))
        @authorization = Authorization.new(config, store, clock: @clock)
        @signer = OpenSSL::PKey.read(F.read(config.path("status.key"), maximum: 1024))
        @authorize = authorize || ->(_request) { }
        @progress, @fault = progress, fault
      end
      def trust
        Releases::Authority.new(NativeHost.load_document(config.path("trust.json"), maximum: 65_536))
      end
      def approve!(operation:, id:, release_id:, confirmation:, snapshot_id: nil, loss_fingerprint: nil)
        config.database!
        store.transaction do |state|
          policy = trust
          policy.apply!(state)
          manifest, plan, = Plan.new(config).load!(release_id, trust: policy, trust_state: state)
          request = store.operation!(state, id: id, operation: operation, release_id: release_id)
          plan_hash = Digest::SHA256.hexdigest(Releases.canonical(plan))
          retained_hash = state.dig("releases", release_id, "plan_sha256")
          raise Error, "native_plan_changed" if retained_hash && retained_hash != plan_hash
          request["plan_sha256"] ||= plan_hash
          raise Error, "native_plan_changed" unless request["plan_sha256"] == plan_hash
          @authorize.call(request)
          raise Error, "completed_operation" if request["completed"]
          challenge = @authorization.prepare!(state, request, confirmation: confirmation,
            snapshot_id: snapshot_id, loss_fingerprint: loss_fingerprint)
          { "request_id" => id, "operation" => operation, "release_id" => release_id,
            "version" => manifest["version"], "challenge" => challenge }
        end
      end
      def dry_run(id)
        NativeHost.uuid!(id)
        state = NativeHost.load_document(config.path("host-journal.json"), maximum: 2_097_152)
        request = state.fetch("operations").fetch(id)
        @authorize.call(request)
        config.database!
        store.import_staging!(state)
        policy = trust
        policy.apply!(state)
        manifest, plan, = Plan.new(config).load!(request["release_id"], trust: policy, trust_state: state)
        { "dry_run" => true, "mutations_performed" => false, "operation" => request["operation"],
          "release_id" => request["release_id"], "version" => manifest["version"], "active" => state["active"],
          "schema_expansion_declared" => !plan["expand"].nil?, "native_approval_recorded" => request["native_approved"] == true,
          "fresh_time_and_backup_gates_not_bypassed" => true }
      rescue KeyError
        raise Error, "unknown_operation"
      end
      def perform(id)
        NativeHost.uuid!(id)
        config.database!
        store.transaction do |state|
          request = state.fetch("operations").fetch(id) { raise Error, "unknown_operation" }
          if request["operation"] == "restore"
            @authorize.call(request)
            raise Error, "legacy_in_place_restore_unsupported"
          end
          begin
            @authorize.call(request)
            return receipt(state, request) if request["completed"]
            runtime.recover_services!(state)
            policy = trust
            policy.apply!(state)
            manifest, plan, publisher = Plan.new(config).load!(request["release_id"], trust: policy, trust_state: state)
            raise Error, "native_plan_changed" unless request["plan_sha256"] == Digest::SHA256.hexdigest(Releases.canonical(plan))
            request["publisher"], request["version"] = publisher, manifest["version"]
            request["metadata"] = manifest.slice("version", "channel", "published_at", "expires_at", "changelog", "compatibility")
            if %w[SWITCHING VERIFYING].include?(request["phase"]) && request["pending"]
              reconcile_switch!(state, request, manifest, plan)
            else
              @authorization.verify!(state, request, manifest, policy)
              raise Error, "stale_host_generation" unless request["expected_generation"] == state["generation"]
              request["error"] = nil
              case request["operation"]
              when "initialize"
                initialize_release!(state, request, manifest, plan)
              when "preflight"
                preflight!(state, request, manifest, plan)
                request["completed"] = true
                phase!(state, request, "READY")
              when "promote", "revert"
                switch_release!(state, request, manifest, plan)
              when "backup"
                backup!(state, request, manifest, plan)
              when "restore"
                restore!(state, request, manifest, plan, policy)
              else raise Error, "operator_operation"
              end
            end
          rescue StandardError => error
            code = error.is_a?(Error) ? error.message : "native_operation_failed"
            code = "native_operation_failed" unless code.match?(/\A[a-z_]{1,100}\z/)
            request["error"] = code
            if request["completed"]
              store.transition!(state, request, request["phase"], detail: code)
            else
              failure!(state, request)
            end
            publish!(state, request)
          end
          result = receipt(state, request)
          store.persist(state)
          result
        end
      end
      def phase!(state, request, phase, detail: nil)
        @authorize.call(request) unless request["completed"]
        store.transition!(state, request, phase, detail: detail)
        publish!(state, request)
        @progress&.call(receipt(state, request))
        @fault&.call(phase)
      rescue Error
        raise
      rescue StandardError
        raise Error, "native_progress_failed"
      end
      def snapshot_ready!(state, policy)
        proof = state["restore_proof"]
        raise Error, "restore_drill_unqualified" unless proof.is_a?(Hash) && proof["completed"] &&
          proof["deployment_id"] == config.data["deployment_id"] && proof["environment_sha256"] == config.data["environment_sha256"]
        id = state["snapshot"]
        raise Error, "snapshot_required" unless id
        Snapshot.new(config, signer: @signer).validate!(id, trust: policy, trust_state: state)
      end
      def fresh_authorization!(state, request)
        store.import_staging!(state)
        policy = trust
        policy.apply!(state)
        manifest, plan, = Plan.new(config).load!(request["release_id"], trust: policy, trust_state: state)
        raise Error, "native_plan_changed" unless request["plan_sha256"] == Digest::SHA256.hexdigest(Releases.canonical(plan))
        @authorize.call(request)
        @authorization.verify!(state, request, manifest, policy)
        [ manifest, plan ]
      end
      def receipt(state, request)
        active = state["active"]
        statement = { "format" => "railpress.host-result.v1", "deployment_id" => config.data["deployment_id"],
          "scope" => config.data["scope"], "request_id" => request["id"], "operation" => request["operation"],
          "release_id" => request["release_id"], "state" => request["phase"], "revision" => request["revision"],
          "version" => request["version"], "publisher" => request["publisher"], "metadata" => request["metadata"] || {},
          "error" => request["error"], "active_release" => active,
          "active_version" => state.dig("releases", active, "version"), "generation" => state["generation"],
          "maintenance" => state["maintenance"], "completed" => request["completed"] == true, "history" => state["events"].select { |row| row["request"] == request["id"] }.last(32) }
        NativeHost.sign(statement, @signer)
      end
      def publish!(state, request = nil, observation: nil)
        key = Releases.key_id(@signer)
        policy = trust
        raise Error, "status_signer_untrusted" unless policy.roots.dig(key, "purpose") == "status" && !policy.revoked.include?(key) && !state["revoked"].include?(key)
        observation ||= observe(state)
        observed, consistent = observation.values_at("proxy", "consistent")
        disk_ready = observation["disk_admission"]
        restore_ready = observation["packages_required"] ? !disk_ready.nil? : state.dig("restore_proof", "completed") == true
        request ||= state["operations"][state["events"].last&.fetch("request")]
        statement = { "format" => "railpress.host-status.v1", "deployment_id" => config.data["deployment_id"],
          "scope" => config.data["scope"], "generation" => state["generation"], "active_release" => state["active"],
          "active_version" => state.dig("releases", state["active"], "version"), "previous_release" => state["previous"],
          "observed_proxy" => observed, "services_healthy" => observation["healthy"], "maintenance" => state["maintenance"], "reconciliation_required" => !consistent || !observation["healthy"] || state["recovery_required"] == true ||
            state["operations"].values.any? { |operation| !operation["completed"] && %w[SWITCHING VERIFYING RESTORING RESTORE_REQUIRED].include?(operation["phase"]) },
          "restore_drill_completed" => restore_ready,
          "snapshot_id" => observation["packages_required"] ? disk_ready&.fetch("snapshot") : state["snapshot"], "observed_elapsed" => SecurityClock.elapsed, "domain" => SecurityClock.boot_domain,
          "last_operation" => request && request.slice("id", "operation", "phase", "error"),
          "capabilities" => [ "preflight" ] + (restore_ready && state["active"] && state["maintenance"] == false && !state["recovery_required"] && consistent && observation["healthy"] &&
            !state["operations"].values.any? { |operation| !operation["completed"] && %w[SWITCHING VERIFYING RESTORING RESTORE_REQUIRED].include?(operation["phase"]) } ? %w[promote revert] : []),
          "production_qualified" => false, "independent_utc_qualified" => false }
        F.atomic(config.app_environment.fetch("RAILPRESS_NATIVE_PUBLIC_STATUS"), Releases.canonical(NativeHost.sign(statement, @signer)), mode: 0o444)
      end
      def observe(state)
        result = { "proxy" => nil, "consistent" => false, "healthy" => false }
        response = runtime.probe.request("/__railpress_deployment")
        result["proxy"] = response["status"] == 200 ? Releases.parse(response["body"], limit: 8192) : nil
        expected = { "release_id" => state["active"], "generation" => state["generation"], "maintenance" => state["maintenance"] }
        result["consistent"] = result["proxy"] == expected
        if result["consistent"] && state["active"] && !state["maintenance"]
          policy = trust
          policy.apply!(state)
          manifest, = Plan.new(config).load!(state["active"], trust: policy, trust_state: state)
          report = runtime.probe.identity!(runtime.probe.health, state["active"], manifest)
          packages = report["package_context"]
          result["packages_required"] = packages ? Releases::PackageContext.required?(packages) :
            !config.app_environment["RAILPRESS_EXTENSION_ROOT"].nil?
          if packages && result["packages_required"]
            require_relative "../recovery"
            begin
              result["disk_admission"] = Railpress::Recovery::Disk.admit_promotion!(config: config,
                release: state["active"], packages: packages, policy: policy, trust_state: state)
            rescue Error
              # Status keeps promotion held until the exact inventory is recovered.
            end
          end
          node = state.fetch("services").fetch(state["active"])
          result["healthy"] = %w[puma worker].all? { |role| runtime.processes.verified(node[role]) } &&
            runtime.processes.verified(state["proxy"])
        end
        result
      rescue Error, KeyError, NoMethodError
        result
      end
      def status
        state = NativeHost.load_document(config.path("host-journal.json"), maximum: 2_097_152)
        observation = observe(state)
        { "journal_active" => state["active"], "observed_proxy" => observation["proxy"],
          "services_healthy" => observation["healthy"],
          "reconciliation_required" => !observation["consistent"] || !observation["healthy"] || state["recovery_required"] == true ||
            state["operations"].values.any? { |row| %w[SWITCHING VERIFYING RESTORING RESTORE_REQUIRED].include?(row["phase"]) && !row["completed"] },
          "maintenance" => state["maintenance"], "generation" => state["generation"],
          "operations" => state["operations"].values.map { |row| row.slice("id", "operation", "release_id", "phase", "error", "completed") },
          "scope" => config.data["scope"], "production_qualified" => false }
      end
    end
  end
end
