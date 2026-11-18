# frozen_string_literal: true

module Railpress
  module NativeHost
    module Recovery
      def initialize_release!(state, request, manifest, plan)
        raise Error, "host_already_initialized" if state["active"] || state["generation"] != 0
        runtime.stop_all_apps!(state)
        state["services"] = {}
        raise Error, "initial_plan_only" unless plan["predecessors"].empty? && plan["expand"].nil? &&
          plan["contract"] == { "schema" => Product::SCHEMA, "write" => Product::SCHEMA, "jobs" => Product::JOB_PAYLOAD, "theme_api" => Product::THEME_API }
        id = request["release_id"]
        phase!(state, request, "PREFLIGHT")
        runtime.prepare_tree!(id, manifest)
        runtime.dependencies!(id, request["id"])
        state["sequence"] ||= {}
        previous = state["sequence"][manifest["channel"]]
        raise Error, "manifest_replay" if previous && previous["sequence"] >= manifest["sequence"] &&
          previous != { "sequence" => manifest["sequence"], "release_id" => id, "request_id" => request["id"] }
        reservation = { "sequence" => manifest["sequence"], "release_id" => id, "request_id" => request["id"] }
        state["sequence"][manifest["channel"]] = reservation
        state["admitted"] ||= {}
        state["admitted"][id] = reservation
        state["services"] ||= {}
        state["releases"][id] = { "version" => manifest["version"], "contract" => plan["contract"], "plan_sha256" => request["plan_sha256"] }
        state["contract"], state["maintenance"], state["recovery_required"] = plan["contract"], false, false
        phase!(state, request, "STAGED")
        report = runtime.start_puma!(state, id, 0)
        runtime.probe.identity!(report, id, manifest)
        raise Error, "installed_theme_continuity" unless report["themes"].all? { |theme| manifest["compatibility"]["themes"].include?(theme) }
        runtime.routes!(plan, slot: 0)
        runtime.worker!(state, id, 0)
        fresh_authorization!(state, request)
        runtime.start_proxy!(state, id, 0)
        runtime.probe.identity!(runtime.probe.health, id, manifest)
        state["active"] = id
        request["completed"] = true
        phase!(state, request, "ACTIVE")
      end
      def backup!(state, request, manifest, _plan)
        raise Error, "backup_target_not_active" unless request["release_id"] == state["active"] && state["maintenance"] == false
        Database.new(config).assert_installation!
        active = state["active"]
        slot = state["services"].fetch(active).fetch("slot")
        phase!(state, request, "BACKING_UP")
        runtime.maintenance!(state, true)
        runtime.stop_all_apps!(state)
        raise Error, "unverified_worker_registration" unless Database.new(config).query("SELECT pid FROM solid_queue_processes").empty?
        report = runtime.quiescent_report(active, slot)
        runtime.probe.identity!(report, active, manifest)
        snapshot = Snapshot.new(config, signer: @signer, fault: @fault).create!(id: request["id"], active: active,
          contract: state.fetch("contract"), clock_binding: report.fetch("clock_binding"), site_report: report)
        state["snapshot"] = snapshot["snapshot_id"]
        request["backup"] = { "snapshot_id" => snapshot["snapshot_id"], "files" => snapshot["files"].length,
          "database_sha256" => snapshot["files"]["database.dump"]["sha256"],
          "elapsed_seconds" => snapshot["completed_elapsed"] - snapshot["captured_elapsed"] }
        store.persist(state)
        runtime.start_puma!(state, active, slot)
        runtime.worker!(state, active, slot)
        runtime.maintenance!(state, false)
        request["completed"] = true
        phase!(state, request, "BACKED_UP")
      end
      def restore!(*, **)
        raise Error, "legacy_in_place_restore_unsupported"
      end
    end
  end
end
