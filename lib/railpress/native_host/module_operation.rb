# frozen_string_literal: true

module Railpress
  module NativeHost
    class ModuleOperation
      FORMAT = "railpress.native-module-approval.v1"
      INTERRUPTED = %w[verifying migrating restarting].freeze

      def initialize(config, runtime: nil)
        @config = config
        @store = State.new(config)
        @runtime = runtime || Runtime.new(config, @store)
      end

      def perform!(id, confirmation:)
        NativeHost.uuid!(id)
        unless %w[w03_bridge w04_recruitment w04_recruitment_final].include?(@config.data["test_database_profile"]) && confirmation == @config.data["deployment_id"]
          raise Error, "module_native_profile"
        end
        @config.database!
        @store.transaction do |state, lock|
          request = ExtensionInstallRequest.find_by!(request_key: id, site_identity: @config.data["install_id"])
          unless state["active"] && ENV["RAILPRESS_DEPLOYMENT_DIGEST"] == state["active"] && request.core_version == Product::VERSION
            raise Error, "module_reconciliation_required"
          end
          if INTERRUPTED.include?(request.state)
            return reconcile_interrupted!(state, request)
          end
          unless state["maintenance"] == false && !state["recovery_required"] && request.state == "awaiting_operator"
            raise Error, "module_reconciliation_required"
          end
          ::Extensions::Requests.locked_owner!(request.actor_id, request.actor_auth_version)
          live = Extensions.registry
          approval = approval!(id, request, state)
          key = OpenSSL::PKey.read(F.read(@config.path("extension-receipt.key"), maximum: 1024))
          begin
            ::Extensions::CatalogHandoff.verify_operator_request!(request, registry: live)
          rescue Extensions::Invalid
            receipt!(request, live, key, "held")
            return interrupted_result(request)
          end
          directory = @config.app_environment.fetch("RAILPRESS_EXTENSION_ROOT")
          selection = F.read(@config.path("approvals", "#{id}.engine-set.json"), maximum: 65_536)
          raise Error, "module_lock_digest" unless Digest::SHA256.hexdigest(selection) == approval["lock_sha256"]
          validate_live!(state, live, request)
          candidate = prospective!(directory, request, selection)
          final_state = request.operation == "uninstall" ? "retained" : "installed"
          validate_contract!(request, candidate, approval) if final_state == "installed"
          repair = approval["repair"]
          raise Error, "module_repair_request" if repair && request.operation != "install"
          receipt!(request, candidate, key, "verifying") unless repair
          state["module_operation"] = { "id" => id, "phase" => "FENCED", "lock" => approval["lock_sha256"] }
          if repair
            state["module_operation"]["repair"] = { "approval_sha256" => Extensions.digest(approval),
              "plan" => repair, "phase" => "STARTED" }
          end
          @store.persist(state)
          begin
            @runtime.maintenance!(state, true)
            @runtime.stop_all_apps!(state)
            if repair
              raise Error, "module_repair_approval_changed" unless approval!(id, request, state) == approval
              evidence = ModuleRepair.new(candidate.entries.fetch(request.module_id)).apply!(request, repair)
              state["module_operation"]["repair"].merge!("phase" => "APPLIED", "evidence" => evidence)
              @store.persist(state)
              receipt!(request, candidate, key, "verifying")
            elsif %w[install upgrade].include?(request.operation)
              receipt!(request, candidate, key, "migrating")
              Extensions::Migrations.apply!(request: request, registry: candidate, lock_path: @config.path("operation.lock"), admitted_lock: lock)
            end
            receipt!(request, candidate, key, "restarting")
            state["module_operation"]["phase"] = "RESTARTING"
            @store.persist(state)
            approval!(id, request, state)
            F.atomic(File.join(directory, "engine-set.json"), selection)
            core = state.fetch("active")
            slot = state.fetch("services").fetch(core).fetch("slot")
            report = @runtime.start_puma!(state, core, slot)
            @runtime.worker!(state, core, slot)
            proof = process_proof!(state, report, candidate)
            @runtime.maintenance!(state, false)
            edge = @runtime.probe.health
            unless edge["release_id"] == core && edge["engine_set_fingerprint"] == candidate.fingerprint && edge["installation_id"] == candidate.site
              raise Error, "module_public_identity"
            end
            approved = approval!(id, request, state)
            raise Error, "module_repair_approval_changed" if repair && approved != approval
            receipt!(request, candidate, key, final_state, processes: proof,
              module_schema: approved["module_schema"], job_revision: approved["job_revision"],
              retention_clear: approved["retention_clear"])
            state["module_operation"]["phase"] = "VERIFIED"
            @store.persist(state)
            { "request_id" => id, "state" => request.reload.state, "enabled" => false }
          rescue StandardError
            begin
              @runtime.maintenance!(state, true) if state["maintenance"] == false
              @runtime.stop_all_apps!(state)
            rescue StandardError
              # Preserve the explicit reconciliation hold when fencing fails.
            end
            state["recovery_required"] = true
            state["module_operation"]["phase"] = "RECOVERY_REQUIRED"
            state["module_operation"]["repair"]["outcome"] = "RECOVERY_REQUIRED" if repair
            @store.persist(state)
            begin
              receipt!(request, candidate, key, "recovery_required") if %w[migrating restarting].include?(request.reload.state)
            rescue StandardError
              # An unknown receipt or stale actor cannot authorize a retry.
            end
            raise
          end
        end
      end

      private

      # An exact retry can report an interrupted step without replaying migrations.
      # An ambiguous or post-mutation operation stays under the native recovery fence.
      def reconcile_interrupted!(state, request)
        approval = approval!(request.request_key, request, state)
        registry = Extensions.registry
        journal = state["module_operation"]
        key = OpenSSL::PKey.read(F.read(@config.path("extension-receipt.key"), maximum: 1024))
        current = ::Extensions::Requests.current_lock?(request, registry)
        if request.state == "verifying" && current && !state["maintenance"] && !state["recovery_required"]
          if journal && journal["id"] == request.request_key
            raise Error, "module_reconciliation_required" unless journal["lock"] == approval["lock_sha256"] && %w[FENCED HELD].include?(journal["phase"])
            journal["phase"] = "HELD"
            @store.persist(state)
          end
          receipt!(request, registry, key, "held")
          return interrupted_result(request)
        end

        unless %w[migrating restarting].include?(request.state) && journal &&
            journal.values_at("id", "lock") == [ request.request_key, approval["lock_sha256"] ] &&
            %w[FENCED RESTARTING RECOVERY_REQUIRED].include?(journal["phase"]) &&
            (current || exact_successor?(request, registry, approval))
          raise Error, "module_reconciliation_required"
        end
        state["recovery_required"] = true
        journal["phase"] = "RECOVERY_REQUIRED"
        @store.persist(state)
        @runtime.maintenance!(state, true) unless state["maintenance"]
        @runtime.stop_all_apps!(state)
        receipt!(request, registry, key, "recovery_required")
        interrupted_result(request)
      end

      def exact_successor?(request, registry, approval)
        directory = @config.app_environment.fetch("RAILPRESS_EXTENSION_ROOT")
        ::Extensions::Requests.successor_lock?(request, registry) &&
          Digest::SHA256.hexdigest(F.read(File.join(directory, "engine-set.json"), maximum: 65_536)) == approval["lock_sha256"]
      end

      def interrupted_result(request)
        { "request_id" => request.request_key, "state" => request.reload.state, "enabled" => false }
      end

      def approval!(id, request, state)
        envelope = NativeHost.load_document(@config.path("approvals", "#{id}.module.json"), maximum: 16_384)
        Releases.keys!(envelope, %w[statement signature])
        statement = envelope.fetch("statement")
        Releases.keys!(statement.except("repair"), %w[format deployment site request lock_sha256 core_release generation domain elapsed module_schema job_revision retention_clear])
        Releases.keys!(statement["repair"], ModuleRepair::FIELDS) if statement.key?("repair")
        policy = Releases::Authority.new(NativeHost.load_document(@config.path("trust.json"), maximum: 65_536))
        policy.apply!(state)
        policy.verify!(Releases.canonical(statement), envelope["signature"], state, purpose: "status")
        expected = [ FORMAT, @config.data["deployment_id"], request.site_identity, ::Extensions::Requests.request_digest(request),
          state["active"], state["generation"], SecurityClock.boot_domain ]
        fields = %w[format deployment site request core_release generation domain]
        elapsed = statement["elapsed"]
        unless statement.values_at(*fields) == expected && elapsed.is_a?(Numeric) && (SecurityClock.elapsed - elapsed).between?(0, 300) &&
            [ true, false ].include?(statement["retention_clear"])
          raise Error, "module_approval_binding"
        end
        Releases.identity!(statement["lock_sha256"])
        ::Extensions::Requests.locked_owner!(request.actor_id, request.actor_auth_version)
        statement
      end

      def validate_live!(state, registry, request)
        unless registry.generation == request.engine_generation && registry.fingerprint == request.engine_fingerprint
          raise Error, "module_previous_lock"
        end
        live = @runtime.probe.health
        unless live["release_id"] == state["active"] && live["installation_id"] == request.site_identity &&
            !live["clock_anomaly"] && live["engine_set_fingerprint"] == registry.fingerprint
          raise Error, "module_predecessor_process"
        end
        raise Error, "module_core_switch_pending" if ::Extensions::Requests.core_switch_pending?(request.site)
      end

      def prospective!(directory, request, bytes)
        config = Releases.parse(bytes, limit: 65_536)
        store = Extensions::EngineSet::Store.new(directory, synthetic: true)
        trust = Extensions::Trust.new(store.read(File.join(directory, "trust.json"), limit: Extensions::Trust::LIMIT))
        set = Extensions::EngineSet.new(config, trust: trust, store: store, expected_site: request.site_identity,
          core_anchor: @config.app_environment.fetch("RAILPRESS_EXTENSION_CORE_ANCHOR"))
        unless set.previous_generation == request.engine_generation && set.previous_fingerprint == request.engine_fingerprint
          raise Error, "module_previous_lock"
        end
        registry = Extensions::Registry.new(set, {})
        selected = set.entries[request.module_id]
        if request.operation == "uninstall"
          raise Error, "module_retention_hold" if selected
        elsif !selected || selected.version != request.version || selected.package_sha256 != request.package_sha256 ||
            selected.manifest.digest != request.manifest_sha256 || selected.plan_sha256 != request.plan_sha256
          raise Error, "module_package_binding"
        end
        registry
      end

      def validate_contract!(request, registry, approval)
        ranges = registry.entries.fetch(request.module_id).manifest.data_contract
        %w[module_schema job_revision].each { |field| Extensions.generation!(approval[field]) }
        fields = { "schema_read" => "module_schema", "schema_write" => "module_schema", "jobs_read" => "job_revision", "jobs_write" => "job_revision" }
        raise Error, "module_data_window" unless fields.all? { |window, key| approval[key].between?(*ranges[window]) }
      end

      def process_proof!(state, report, registry)
        id = state.fetch("active")
        node = state.fetch("services").fetch(id)
        web, supervisor = node.values_at("puma", "worker")
        proof = node.fetch("worker_proof")
        children = Array(node["worker_children"])
        worker = children.find { |row| row["pid"] == proof["pid"] }
        unless report["installation_id"] == registry.site && report["release_id"] == id && !report["clock_anomaly"] &&
            report["engine_set_fingerprint"] == registry.fingerprint && proof["engine_set_fingerprint"] == registry.fingerprint &&
            [ web, supervisor, worker ].all? { |identity| @runtime.processes.verified(identity) }
          raise Error, "module_process_identity"
        end
        { "web" => { "pid" => web["pid"], "healthy" => true, "fingerprint" => registry.fingerprint },
          "worker" => { "pid" => worker["pid"], "healthy" => true, "fingerprint" => registry.fingerprint } }
      end

      def receipt!(request, registry, key, status, processes: nil, module_schema: nil, job_revision: nil, retention_clear: false)
        now = Time.now.to_i
        statement = { "format" => Extensions::Trust::RECEIPT, "id" => request.module_id,
          "request_sha256" => ::Extensions::Requests.request_digest(request), "sequence" => request.reload.receipt_sequence + 1,
          "issued_at" => now, "expires_at" => now + 60, "state" => status, "engine_generation" => registry.generation,
          "engine_fingerprint" => registry.fingerprint, "processes" => processes, "module_schema" => module_schema,
          "job_revision" => job_revision, "retention_clear" => retention_clear }
        bytes = Releases.canonical(NativeHost.sign(statement, key))
        ::Extensions::Requests.accept!(request_key: request.request_key, envelope: bytes, registry: registry)
      end
    end
  end
end
