module Seo
  module Diagnostics
    class Invalid < StandardError; end
    LIMITS = { "offline" => 250, "http" => 120 }.freeze
    BATCH_SIZE = 5
    TARGET_SECONDS = 8
    STALL_AFTER = 10.minutes
    RUN_WINDOW = 20.minutes
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
        if active && active.updated_at < STALL_AFTER.ago
          active.finish!("failed", active.summary.merge("codes" => [ "stalled_run_replaced" ]))
          active = nil
        end
        next active if active
        entries = UrlInventory.call(site: site)
        candidate = DiagnosticRun.create!(requester: actor, active_key: "site", mode: mode, origin: site.canonical_origin, generation: site.seo_generation,
          summary: { "inventory_count" => entries.length, "source" => "configured_public_policy", "codes" => [],
            "indexing_override_disabled" => operator_indexing_disabled? })
        limit = LIMITS.fetch(mode)
        if entries.length > limit
          candidate.finish!("failed", candidate.summary.merge("codes" => [ "inventory_limit_exceeded" ], "limit" => limit))
        else
          entries.each_with_index { |entry, index| candidate.diagnostic_targets.create!(url: entry.url, family: entry.family, position: index, result: {}) }
          created = true
        end
        Activity::Recorder.record!(actor: actor, action: "seo.requested", subject: candidate)
        candidate
      end
      enqueue!(run, 0) if created
      run
    end

    def operator_indexing_disabled?
      ENV["RAILPRESS_SEO_INDEXING"] == "disabled"
    end

    def enqueue!(run, position)
      job = SeoDiagnosticJob.perform_later(run.id)
      raise Invalid unless job
    rescue StandardError
      run.with_lock do
        if run.active_key && run.summary.fetch("checked", 0) == position && !run.summary["checking_batch"]
          run.finish!("failed", run.summary.merge("codes" => [ "queue_unavailable" ]))
        end
      end
    end

    def current!(run, site)
      actor = User.lock.find_by(id: run.requester_id)
      Identity::Capabilities.allowed?(actor, :execute_seo) && site.canonical_origin == run.origin && site.seo_generation == run.generation &&
        run.summary.fetch("indexing_override_disabled", operator_indexing_disabled?) == operator_indexing_disabled? &&
        (run.mode != "http" || ENV["RAILPRESS_SEO_HTTP_ENABLED"] == "1")
    end

    def execute!(id, position = nil, client: nil, resolver: nil)
      run = DiagnosticRun.find(id)
      position ||= run.summary.fetch("checked", 0)
      claimed = claim_batch!(run, position)
      return run unless claimed

      targets = run.diagnostic_targets.where(position: position...(position + BATCH_SIZE)).order(:position).to_a
      expected_positions = (position...[ position + BATCH_SIZE, run.summary.fetch("inventory_count") ].min).to_a
      raise Invalid unless targets.map(&:position) == expected_positions

      site = Site.find_by!(singleton_key: 1)
      entries = UrlInventory.call(site: site) if run.mode == "offline" || position.zero?
      report = SitemapReport.new(site: site, entries: entries) if position.zero?
      codes = run.summary.fetch("codes") + Array(report&.codes)
      validator = http_validator(run, client, resolver) if run.mode == "http"
      eligible = entries&.index_by(&:url)
      targets.each do |target|
        return run unless recheck!(run)

        result = validator ? check_http(validator, target.url) : check_offline(target, eligible)
        target.update!(result: result, checked_at: Time.current)
        codes.concat(result.fetch("codes"))
      end
      return run unless recheck!(run)

      checked = position + targets.size
      next_batch = finish_batch!(run, checked, codes)
      next_batch ? enqueue!(run, checked) : prune!
      run
    rescue StandardError => error
      if claimed
        run.with_lock do
          if run.active_key
            checked = run.diagnostic_targets.where.not(checked_at: nil).count
            run.finish!("failed", run.summary.merge("codes" => [ "execution_unavailable" ], "checked" => checked))
          end
        end
      end
      Rails.logger.warn("SEO diagnostics unavailable (#{error.class.name}); public rendering remains independent")
      run
    end

    def claim_batch!(run, position)
      Site.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        run.lock!
        next false unless run.active_key && !run.summary["checking_batch"] && run.summary.fetch("checked", 0) == position
        next false unless check_authority!(run, site)

        run.update!(status: "running", started_at: run.started_at || Time.current, summary: run.summary.merge("checking_batch" => true))
        true
      end
    end

    def recheck!(run)
      Site.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        run.lock!
        run.active_key && check_authority!(run, site)
      end
    end

    def check_authority!(run, site)
      unless current!(run, site)
        run.finish!("cancelled", run.summary.merge("codes" => [ "authority_or_policy_changed" ]))
        return false
      end
      if run.started_at && run.started_at < RUN_WINDOW.ago
        run.finish!("failed", run.summary.merge("codes" => [ "run_deadline" ]))
        return false
      end
      true
    end

    def http_validator(run, client, resolver)
      options = { origin: run.origin, allowed_urls: run.diagnostic_targets.order(:position).pluck(:url) }
      options[:resolver] = resolver if resolver
      HttpValidator.new(guard: HttpTargetGuard.new(**options), client: client || NetHttpClient.new)
    end

    def check_http(validator, url)
      Timeout.timeout(TARGET_SECONDS) { validator.call(url) }
    rescue Timeout::Error
      { "codes" => [ "timeout" ], "http_status" => nil }
    end

    def check_offline(target, eligible)
      matches = eligible[target.url]&.family == target.family
      { "codes" => matches ? [] : [ "target_inventory_mismatch" ], "source" => "offline_policy", "canonical" => target.url, "indexable" => matches }
    end

    def finish_batch!(run, checked, codes)
      run.with_lock do
        next false unless run.active_key

        total = run.summary.fetch("inventory_count")
        summary = run.summary.merge("checked" => checked, "checking_batch" => false, "codes" => codes.uniq.first(30))
        if checked >= total
          run.finish!("completed", summary)
          false
        else
          run.update!(summary: summary)
          true
        end
      end
    end

    def prune!
      DiagnosticRun.where(active_key: nil).order(id: :desc).offset(25).each(&:destroy!)
    end
  end
end
