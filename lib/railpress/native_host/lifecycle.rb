# frozen_string_literal: true

module Railpress
  module NativeHost
    module Lifecycle
      def preflight!(state, request, manifest, plan)
        Database.new(config).assert_installation!
        raise Error, "active_release_unknown" unless state["active"] && state["maintenance"] == false && !state["recovery_required"]
        policy = trust
        policy.apply!(state)
        current_manifest, = Plan.new(config).load!(state["active"], trust: policy, trust_state: state)
        current_slot = state.fetch("services").fetch(state["active"]).fetch("slot")
        report = runtime.probe.identity!(runtime.probe.health(slot: current_slot), state["active"], current_manifest)
        edge = runtime.probe.identity!(runtime.probe.health, state["active"], current_manifest)
        route = runtime.probe.request("/__railpress_deployment")
        observed = Releases.parse(route["body"], limit: 8192)
        raise Error, "journal_proxy_mismatch" unless route["status"] == 200 &&
          observed == { "release_id" => state["active"], "generation" => state["generation"], "maintenance" => false } &&
          same_site?(report, edge)
        raise Error, "installed_theme_continuity" unless report["themes"].is_a?(Array) &&
          report["themes"].all? { |theme| manifest["compatibility"]["themes"].include?(theme) }
        c = manifest["compatibility"]
        { "ruby" => RUBY_VERSION, "rails" => Gem::Specification.find_by_name("rails").version.to_s }.each do |key, actual|
          raise Error, "incompatible_#{key}" unless Releases::Manifest.requirement!(c[key]).satisfied_by?(Gem::Version.new(actual))
        end
        _, identity = config.database!
        raise Error, "database_version" unless Releases::Manifest.requirement!(c["databases"].fetch(config.data["engine"])).satisfied_by?(Gem::Version.new(identity["version"][/\A\d+(?:\.\d+){1,3}/]))
        if request["operation"] == "revert"
          raise Error, "revert_not_retained_predecessor" unless request["release_id"] == state["previous"]
          Schema.new(config).revert_eligible!(manifest, state.fetch("contract"))
          Plan.new(config).tree!(request["release_id"], manifest)
        else
          raise Error, "unsupported_predecessor" unless plan["predecessors"].include?(state["active"]) &&
            c["prior_versions"].include?(current_manifest["version"])
          raise Error, "product_not_newer" unless Releases.compare_versions(manifest["version"], current_manifest["version"]).positive?
          schema = Schema.new(config)
          schema.revert_eligible!(manifest, plan["contract"])
          schema.revert_eligible!(current_manifest, plan["contract"])
          if plan["expand"]
            raise Error, "schema_start_contract" unless [ plan["expand"]["schema_from"], plan["expand"]["schema_to"] ].include?(state.dig("contract", "schema"))
          else
            raise Error, "undeclared_schema_change" unless plan["contract"] == state["contract"]
          end
          snapshot_ready!(state, policy)
        end
        require_admission!(state, request, manifest) if %w[promote revert].include?(request["operation"])
        expected = config.data.fetch("dependency_hashes")
        raise Error, "unreviewed_dependency_definition" unless expected.all? { |name, hash| manifest.dig("files", name, "sha256") == hash }
        bytes = F.read(config.path("inbox", request["release_id"], "package.tar.gz"), maximum: Releases::Manifest::MAX_PACKAGE)
        raise Error, "package_digest" unless bytes.bytesize == manifest["package"]["bytes"] && Digest::SHA256.hexdigest(bytes) == manifest["package"]["sha256"]
        request["before_report"] = report
        request["runtime_checks"] = { "ruby" => RUBY_VERSION, "rails" => Gem::Specification.find_by_name("rails").version.to_s,
          "database" => identity, "theme_continuity" => true, "schema_and_job_windows" => true }
        store.persist(state)
        report
      end
      def require_admission!(state, request, manifest)
        id = request["release_id"]
        state["admitted"] ||= {}
        unless state["admitted"][id]
          path = config.path("journal.json")
          raise Error, "verified_stage_required" unless File.exist?(path)
          legacy = NativeHost.load_document(path)
          reservation = legacy.fetch("sequence", {})[manifest["channel"]]
          staged = legacy.fetch("requests", {}).values.any? { |row| row["release_id"] == id && row["state"] == "STAGED" }
          raise Error, "verified_stage_required" unless staged && reservation &&
            reservation["release_id"] == id && reservation["sequence"] == manifest["sequence"]
          state["admitted"][id] = reservation
        end
        if request["operation"] == "promote"
          highest = state.fetch("sequence", {})[manifest["channel"]]
          raise Error, "manifest_replay" unless highest && highest["release_id"] == id && highest["sequence"] == manifest["sequence"]
        end
      end
      def switch_release!(state, request, manifest, plan)
        preflight!(state, request, manifest, plan)
        id, old_id = request["release_id"], state["active"]
        old_slot = state["services"].fetch(old_id).fetch("slot")
        slot = 1 - old_slot
        phase!(state, request, request["operation"] == "revert" ? "REVERT_ELIGIBILITY_CHECK" : "PREFLIGHT")
        runtime.prepare_tree!(id, manifest)
        runtime.dependencies!(id, request["id"])
        state["releases"][id] = { "version" => manifest["version"], "contract" => plan["contract"], "plan_sha256" => request["plan_sha256"] }
        phase!(state, request, "STAGED")
        if request["operation"] == "promote" && plan["expand"]
          request["schema_progress"] = Schema.new(config).apply!(plan["expand"], progress: ->(row) {
            request["schema_progress"] = row
            store.persist(state)
          }, fault: @fault)
          state["contract"] = plan["contract"]
        end
        phase!(state, request, "SCHEMA_EXPANDED")
        report = runtime.start_puma!(state, id, slot)
        runtime.probe.identity!(report, id, manifest)
        raise Error, "candidate_continuity" unless same_site?(request["before_report"], report)
        request["routes"] = runtime.routes!(plan, slot: slot)
        phase!(state, request, "WARMED")
        runtime.stop_worker!(state, old_id)
        runtime.worker!(state, id, slot)
        phase!(state, request, "READY")
        fresh_authorization!(state, request)
        raise Error, "candidate_worker_failed" unless runtime.processes.verified(state["services"].fetch(id)["worker"])
        latest = runtime.probe.identity!(runtime.probe.health(slot: old_slot), old_id,
          Plan.new(config).load!(old_id, trust: trust, trust_state: state).first)
        raise Error, "concurrent_site_change" unless same_site?(request["before_report"], latest)
        request["pending"] = { "old" => old_id, "target" => id, "old_slot" => old_slot, "slot" => slot,
          "generation" => state["generation"] + 1, "authorized_cutover" => true }
        phase!(state, request, "SWITCHING")
        runtime.proxy.switch!(state.fetch("proxy"), id: id, slot: slot, generation: request["pending"]["generation"])
        @fault&.call("after_proxy_switch")
        phase!(state, request, "VERIFYING")
        finish_switch!(state, request, manifest, plan)
      end
      def same_site?(left, right)
        %w[installation_id theme business_fingerprints clock_binding].all? { |key| left[key] == right[key] }
      end
      def finish_switch!(state, request, manifest, plan)
        pending = request.fetch("pending")
        report = runtime.probe.identity!(runtime.probe.health, pending["target"], manifest)
        raise Error, "public_cutover_continuity" unless same_site?(request["before_report"], report)
        runtime.routes!(plan, slot: nil)
        raise Error, "candidate_worker_failed" unless runtime.processes.verified(state["services"].fetch(pending["target"])["worker"])
        runtime.stop_puma!(state, pending["old"])
        state["previous"], state["active"], state["generation"] = pending["old"], pending["target"], pending["generation"]
        state["releases"][pending["target"]] = { "version" => manifest["version"], "contract" => plan["contract"], "plan_sha256" => request["plan_sha256"] }
        request["completed"] = true
        phase!(state, request, request["operation"] == "revert" ? "PREVIOUS_ACTIVE" : "ACTIVE")
      end
      def reconcile_switch!(state, request, manifest, plan)
        pending = request.fetch("pending")
        raise Error, "cutover_authorization_missing" unless pending["authorized_cutover"]
        result = runtime.probe.request("/__railpress_deployment")
        observed = Releases.parse(result["body"], limit: 8192)
        if result["status"] == 200 && observed["release_id"] == pending["target"] && observed["generation"] == pending["generation"]
          finish_switch!(state, request, manifest, plan)
        elsif result["status"] == 200 && observed["release_id"] == pending["old"] && observed["generation"] == state["generation"]
          request["error"] = "interrupted_before_cutover"
          failure!(state, request)
        else
          require_recovery!(state, request, "proxy_state_unreconciled")
        end
      end
      def failure!(state, request)
        if request["error"] == "journal_proxy_mismatch"
          require_recovery!(state, request, request["error"])
          return
        end
        if state["restore_pending"] || %w[RESTORING RESTORE_REQUIRED].include?(request["phase"])
          require_recovery!(state, request, request["error"])
          return
        end
        pending = request["pending"]
        if pending
          begin
            observed = Releases.parse(runtime.probe.request("/__railpress_deployment")["body"], limit: 8192)
            if observed["release_id"] == pending["target"]
              policy = trust
              policy.apply!(state)
              old_manifest, = Plan.new(config).load!(pending["old"], trust: policy, trust_state: state)
              Schema.new(config).revert_eligible!(old_manifest, state.fetch("contract"))
              @authorization.verify!(state, request.merge("release_id" => pending["old"]), old_manifest, policy)
              runtime.start_puma!(state, pending["old"], pending["old_slot"])
              generation = pending["generation"] + 1
              runtime.proxy.switch!(state.fetch("proxy"), id: pending["old"], slot: pending["old_slot"], generation: generation)
              runtime.stop_worker!(state, pending["target"])
              runtime.worker!(state, pending["old"], pending["old_slot"])
              runtime.stop_puma!(state, pending["target"])
              state["active"], state["previous"], state["generation"] = pending["old"], pending["target"], generation
              store.transition!(state, request, "PREVIOUS_ACTIVE", detail: request["error"])
              return
            end
            raise Error, "proxy_state_unreconciled" unless observed["release_id"] == pending["old"]
          rescue Error
            require_recovery!(state, request, request["error"])
            return
          end
        end
        if request["operation"] == "initialize" && state["active"].nil?
          runtime.stop_all_apps!(state)
          runtime.processes.stop(state["proxy"]) if state["proxy"]
          state["services"] = {}
          state["proxy"] = nil
          store.transition!(state, request, "FAILED_STAGED", detail: request["error"])
          return
        end
        if state["active"]
          state["services"].each_key do |id|
            next if id == state["active"]
            runtime.stop_worker!(state, id)
            runtime.stop_puma!(state, id)
          end
          active = state["active"]
          policy = trust
          policy.apply!(state)
          Plan.new(config).load!(active, trust: policy, trust_state: state)
          runtime.start_puma!(state, active, state["services"].fetch(active).fetch("slot"))
          runtime.worker!(state, active, state["services"].fetch(active).fetch("slot"))
          runtime.maintenance!(state, false) if state["maintenance"]
        end
        store.transition!(state, request, "FAILED_STAGED", detail: request["error"])
      rescue StandardError
        require_recovery!(state, request, "manual_native_reconciliation_required")
      end
      def require_recovery!(state, request, detail)
        state["recovery_required"] = true
        begin
          runtime.maintenance!(state, true) if state["active"] && state["proxy"]
        rescue StandardError
          state["maintenance"] = nil
        end
        store.transition!(state, request, "RESTORE_REQUIRED", detail: detail)
      end
    end
  end
end
