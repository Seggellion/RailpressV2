# frozen_string_literal: true

module Railpress
  module NativeHost
    # Foreground, unprivileged fixture supervisor. A host service manager must
    # supervise this process on a separately provisioned production profile.
    class Supervisor
      def initialize(host) = @host = host
      def run(once: false)
        stopping = false
        %w[INT TERM].each { |name| Signal.trap(name) { stopping = true } } unless once
        loop do
          tick
          break if once || stopping
          50.times do
            break if stopping
            sleep 0.1
          end
        end
      end
      def tick
        @host.config.database!
        previous = NativeHost.load_document(@host.config.path("host-journal.json"), maximum: 2_097_152)
        observed_at = SecurityClock.elapsed
        observation = @host.observe(previous)
        @host.store.transaction do |state|
          # Network health checks occur outside the operation lock. Recheck the
          # journal identity before publishing this bounded-age observation.
          next unless %w[active generation maintenance operations].all? { |key| state[key] == previous[key] } &&
            SecurityClock.elapsed - observed_at <= 5
          restarted = false
          @host.runtime.recover_services!(state)
          pending = state["operations"].values.any? { |row| !row["completed"] && %w[SWITCHING VERIFYING RESTORING RESTORE_REQUIRED].include?(row["phase"]) }
          unless pending || state["maintenance"] || state["recovery_required"] || !state["active"]
            id = state["active"]
            node = state["services"].fetch(id)
            if !@host.runtime.processes.verified(node["puma"]) || !@host.runtime.processes.verified(node["worker"])
              policy = @host.trust
              policy.apply!(state)
              manifest, = Plan.new(@host.config).load!(id, trust: policy, trust_state: state)
              Plan.new(@host.config).tree!(id, manifest)
              Schema.new(@host.config).revert_eligible!(manifest, state.fetch("contract"))
              restart = state["supervisor_restarts"] ||= []
              restart.reject! { |row| row["domain"] != SecurityClock.boot_domain || SecurityClock.elapsed - row["elapsed"] > 300 }
              raise Error, "supervisor_restart_budget" if restart.length >= 3
              restart << { "domain" => SecurityClock.boot_domain, "elapsed" => SecurityClock.elapsed, "release_id" => id }
              @host.store.persist(state)
              report = @host.runtime.start_puma!(state, id, node["slot"])
              @host.runtime.probe.identity!(report, id, manifest)
              @host.runtime.stop_worker!(state, id) unless @host.runtime.processes.verified(node["worker"])
              @host.runtime.worker!(state, id, node["slot"])
              restarted = true
            end
          end
          @host.publish!(state, observation: restarted ? nil : observation)
        end
      rescue Error => failure
        return if failure.message == "operation_busy"
        @host.store.transaction do |state|
          state["supervisor_error"] = failure.message
          @host.publish!(state)
        end
      end
    end
  end
end
