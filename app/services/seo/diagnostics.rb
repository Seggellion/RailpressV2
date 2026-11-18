module Seo
  module Diagnostics
    class Invalid < StandardError; end
    module_function
    def start!(actor:, mode: "offline")
      raise Invalid, "Choose offline or HTTP" unless %w[offline http].include?(mode)
      raise Invalid, "HTTP diagnostics require operator configuration" if mode == "http" && ENV["RAILPRESS_SEO_HTTP_ENABLED"] != "1"
      created = false
      run = Site.transaction do
        site = Site.find_by!(singleton_key: 1); site.lock!
        actor.lock!
        Identity::Capabilities.require!(actor, :execute_seo)
        active = DiagnosticRun.where(active_key: "site").lock.first
        if active && active.updated_at < 10.minutes.ago
          active.finish!("failed", { "codes" => [ "stalled_run_replaced" ] })
          active = nil
        end
        next active if active
        entries = UrlInventory.call(site: site)
        candidate = DiagnosticRun.create!(requester: actor, active_key: "site", mode: mode, origin: site.canonical_origin, generation: site.seo_generation,
          summary: { "inventory_count" => entries.length, "source" => "configured_public_policy", "codes" => [] })
        limit = mode == "http" ? 10 : 50
        if entries.length > limit
          candidate.finish!("failed", candidate.summary.merge("codes" => [ "inventory_limit_exceeded" ], "limit" => limit))
        else
          entries.each_with_index { |entry, index| candidate.diagnostic_targets.create!(url: entry.url, family: entry.family, position: index, result: {}) }
          created = true
        end
        Activity::Recorder.record!(actor: actor, action: "seo.requested", subject: candidate)
        candidate
      end
      if created
        begin
          SeoDiagnosticJob.perform_later(run.id)
        rescue StandardError
          run.with_lock { run.finish!("failed", run.summary.merge("codes" => [ "queue_unavailable" ])) if run.status == "pending" }
        end
      end
      run
    end
    def current!(run, site)
      actor = User.lock.find_by(id: run.requester_id)
      Identity::Capabilities.allowed?(actor, :execute_seo) && site.canonical_origin == run.origin && site.seo_generation == run.generation &&
        (run.mode != "http" || ENV["RAILPRESS_SEO_HTTP_ENABLED"] == "1")
    end
    def execute!(id, client: nil, resolver: nil)
      run = DiagnosticRun.find(id)
      claimed = Site.transaction do
        site = Site.find_by!(singleton_key: 1); site.lock!; run.lock!
        next false unless run.status == "pending"
        unless current!(run, site)
          run.finish!("cancelled", run.summary.merge("codes" => [ "authority_or_policy_changed" ])); next false
        end
        run.update!(status: "running", started_at: Time.current)
        true
      end
      return run unless claimed
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      site = Site.find_by!(singleton_key: 1)
      entries = UrlInventory.call(site: site)
      document = Nokogiri::XML(SitemapCache.fetch(site: site).xml) { |config| config.strict.nonet }
      listed = document.xpath("//*[local-name()='url']/*[local-name()='loc']").map(&:text)
      codes = listed.sort == entries.map(&:url).sort && listed.uniq.length == listed.length ? [] : [ "sitemap_inventory_mismatch" ]
      options = { origin: run.origin, allowed_urls: run.diagnostic_targets.order(:position).pluck(:url) }
      options[:resolver] = resolver if resolver
      validator = HttpValidator.new(guard: HttpTargetGuard.new(**options), client: client || NetHttpClient.new)
      run.diagnostic_targets.order(:position).each do |target|
        allowed = Site.transaction do
          current = Site.find_by!(singleton_key: 1); current.lock!; run.lock!
          run.status == "running" && current!(run, current)
        end
        unless allowed
          run.with_lock { run.finish!("cancelled", run.summary.merge("codes" => [ "authority_or_policy_changed" ])) if run.status == "running" }
          return run
        end
        raise Invalid, "run_deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        result = run.mode == "http" ? validator.call(target.url) : { "codes" => [], "source" => "offline_policy", "canonical" => target.url, "indexable" => true }
        target.update!(result: result, checked_at: Time.current)
        codes.concat(result.fetch("codes"))
      end
      run.with_lock do
        run.finish!("completed", run.summary.merge("checked" => run.diagnostic_targets.where.not(checked_at: nil).count, "codes" => codes.uniq.first(30))) if run.status == "running"
      end
      prune!
      run
    rescue StandardError => error
      run&.with_lock { run.finish!("failed", run.summary.merge("codes" => [ "execution_unavailable" ])) if %w[pending running].include?(run.status) }
      Rails.logger.warn("SEO diagnostics unavailable (#{error.class.name}); public rendering remains independent")
      run
    end
    def prune!
      DiagnosticRun.where(active_key: nil).order(id: :desc).offset(25).each(&:destroy!)
    end
  end
end
