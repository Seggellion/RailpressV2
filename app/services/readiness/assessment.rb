module Readiness
  module Assessment
    class Conflict < StandardError; end
    TTL = 3.minutes
    module_function
    def fingerprint(site)
      { "media_configuration" => MediaLibrary::Configuration.fingerprint, "storage_intent" => MediaLibrary::Configuration.intent, "storage_worker" => MediaLibrary::Configuration.worker_identity, "site_version" => site.updated_at.iso8601(6), "seo" => site.seo_generation,
        "theme" => ThemeState.find_by(site: site)&.lock_version || 0,
        "official_news" => OfficialNewsState.find_by(site: site)&.lock_version || 0,
        "navigation" => Navigation::Mutation.generation(site),
        "content" => [ Content.count, Content.maximum(:updated_at)&.iso8601(6) ],
        "media" => [ MediaAsset.count, MediaAsset.maximum(:updated_at)&.iso8601(6) ] }
    end
    def request!(actor:)
      created = false
      run = Site.transaction do
        site = Site.find_by!(singleton_key: 1); site.lock!; actor.lock!
        Identity::Capabilities.require!(actor, :view_readiness)
        existing = ReadinessRun.where(site: site, active_slot: 1).lock.first
        next existing if existing
        created = true
        candidate = ReadinessRun.create!(site: site, actor: actor, auth_version: actor.auth_version, active_slot: 1)
        Activity::Recorder.record!(actor: actor, action: "readiness.requested", subject: candidate)
        candidate
      end
      if created
        begin
          AssessReadinessJob.perform_later(run.id)
        rescue StandardError
          run.with_lock { run.update!(state: "failed", active_slot: nil, failure_code: "queue_unavailable") if run.state == "pending" }
        end
      end
      run
    end
    def cancel!(actor:, run:, version:)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!; actor.lock!
        Identity::Capabilities.require!(actor, :view_readiness)
        run.lock!
        raise Conflict, "Assessment changed. Reload before cancelling." unless run.lock_version.to_s == version.to_s && %w[pending running].include?(run.state)
        run.update!(state: "cancelled", active_slot: nil, failure_code: "operator_cancelled")
        Activity::Recorder.record!(actor: actor, action: "readiness.cancelled", subject: run)
      end
    end
    def current?(run, at: Time.current)
      run&.state == "complete" && run.observed_at && run.observed_at <= at &&
        run.observed_at >= at - TTL && run.fingerprint == fingerprint(run.site.reload)
    end
    def authorized?(run)
      actor = User.lock.find_by(id: run.actor_id)
      actor && actor.auth_version == run.auth_version && Identity::Capabilities.allowed?(actor, :view_readiness)
    end
    def execute!(id)
      run = ReadinessRun.find(id)
      claimed = Site.transaction do
        site = run.site; site.lock!; run.lock!
        next false unless run.state == "pending"
        unless authorized?(run)
          run.update!(state: "cancelled", active_slot: nil, failure_code: "authority_changed"); next false
        end
        run.update!(state: "running", started_at: Time.current, fingerprint: fingerprint(site))
        true
      end
      return run unless claimed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      wall = Time.current
      findings = Probes.call(run.site.reload)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      ended = Time.current
      Site.transaction do
        site = run.site.reload; site.lock!; run.lock!
        next unless run.state == "running"
        if !authorized?(run) || fingerprint(site) != run.fingerprint
          run.update!(state: "cancelled", active_slot: nil, failure_code: "authority_or_configuration_changed")
        else
          delta = ended.to_f - wall.to_f - elapsed
          findings << Probes.cell("clock_observation", delta.abs > 2 ? "DEGRADED" : "UNKNOWN",
            delta.abs > 2 ? "Wall and monotonic elapsed time diverged; historical clock conditions remain open." : "This short observation does not qualify host clock reliability.")
          run.update!(state: "complete", active_slot: nil, findings: findings, observed_at: ended,
            timing: { "elapsed_ms" => (elapsed * 1000).round, "wall_delta_ms" => (delta * 1000).round })
          Activity::Recorder.record!(actor: run.actor, action: "readiness.completed", subject: run)
        end
        ids = ReadinessRun.where(site: site, active_slot: nil).order(id: :desc).offset(20).limit(100).pluck(:id)
        ReadinessRun.where(id: ids).delete_all
      end
      run
    rescue StandardError => error
      run&.with_lock { run.update!(state: "failed", active_slot: nil, failure_code: "assessment_unavailable") if %w[pending running].include?(run.state) }
      Rails.logger.warn("Readiness assessment unavailable (#{error.class.name})")
      run
    end
  end
end
