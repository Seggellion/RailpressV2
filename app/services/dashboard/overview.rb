module Dashboard
  class Overview
    attr_reader :site, :actor, :counts, :public_counts, :drafts, :activity, :media, :operations, :news, :clock_held
    def initialize(actor:)
      @actor=actor
      @site=Site.find_by!(singleton_key: 1)
      Identity::Capabilities.require!(actor, :admin)
      @clock_held=!Railpress::SecurityClock.for_application.sample["anomaly"].nil?
      scope=Identity::Capabilities.allowed?(actor, :edit_others) ? Content.where(nil) : Content.where(author_id: actor.id)
      @counts=scope.group(:type, :status).count
      @public_counts=scope.merge(Content.publicly_visible).group(:type).count
      @drafts=scope.where(status: %w[draft pending scheduled]).or(scope.where(pending_review: true))
        .includes(:author).order(id: :desc).limit(6).to_a
      @activity=Activity::Recorder.scope_for(actor).order(id: :desc).limit(5).to_a
      library=MediaLibrary::Policy.scope(actor)
      @media={ "ready"=>library.ready.count, "bytes"=>library.ready.sum(:byte_size), "unavailable"=>library.where.not(state: "ready").count }
      @news=OfficialNews::Cache.view(OfficialNewsState.find_by(site: site))
      @operations=Identity::Capabilities.allowed?(actor, :view_readiness) ? operating_summary : nil
    end
    def count(kind, state)=counts.fetch([ kind, state ], 0)
    def public_count(kind)=public_counts.fetch(kind, 0)
    private
    def operating_summary
      clock=Railpress::SecurityClock.for_application.sample
      run=ReadinessRun.order(id: :desc).first
      valid=Readiness::Assessment.current?(run) && !clock["anomaly"]
      findings=run&.findings
      valid &&= findings.is_a?(Array) && findings.length<=32 && findings.all? { |row|
        row.is_a?(Hash) && row.keys.sort==%w[detail key state] && row["key"].is_a?(String) &&
          row["state"].in?(%w[HEALTHY DEGRADED UNKNOWN UNSUPPORTED]+[ "ACTION REQUIRED" ]) && row["detail"].is_a?(String) && row["detail"].length<=2000
      }
      findings=[] unless valid
      theme=ThemeState.includes(:active_installation, :active_overlay).find_by(site: site)
      heartbeat=SolidQueue::Process.where(kind: "Worker").order(last_heartbeat_at: :desc).pick(:last_heartbeat_at)
      age=heartbeat && Time.current-heartbeat
      worker=!clock["anomaly"] && age&.between?(0, 60) ? "RECENT HEARTBEAT" : "UNKNOWN"
      { "readiness_state"=>valid ? "DATED OBSERVATION" : (run ? "STALE / UNKNOWN" : "UNKNOWN"),
        "findings"=>findings, "readiness_observed_at"=>run&.observed_at,
        "theme"=>theme&.active_installation&.then { |package| "#{package.theme_key} #{package.version}" },
        "overlay"=>theme&.active_overlay&.number, "worker"=>worker, "worker_at"=>heartbeat,
        "pending"=>SolidQueue::ReadyExecution.count+SolidQueue::ScheduledExecution.count+SolidQueue::BlockedExecution.count,
        "failed"=>SolidQueue::FailedExecution.count,
        "navigation_assigned"=>MenuLocation.where(site: site).where.not(published_menu_id: nil).count,
        "navigation_condition"=>findings.find { |f|f["key"]=="menus" } || { "state"=>"UNKNOWN", "detail"=>"Request a dated assessment to inspect unavailable targets." },
        "storage"=>findings.select { |f|%w[storage storage_capacity].include?(f["key"]) },
        "seo"=>findings.find { |f|f["key"]=="seo" } || { "state"=>"UNKNOWN", "detail"=>"Sitemap equivalence has no current saved observation." },
        "release"=>Identity::Capabilities.allowed?(actor, :inspect_updates) ? Releases::HostStatus.read : nil }
    rescue StandardError
      { "readiness_state"=>"UNKNOWN", "findings"=>[], "worker"=>"UNKNOWN", "theme"=>nil,
        "navigation_condition"=>{ "state"=>"UNKNOWN", "detail"=>"Local evidence unavailable." }, "seo"=>{ "state"=>"UNKNOWN", "detail"=>"Local evidence unavailable." }, "storage"=>[] }
    end
  end
end
