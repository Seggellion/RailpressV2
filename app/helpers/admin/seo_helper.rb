# frozen_string_literal: true

module Admin
  module SeoHelper
    def seo_run_status(run)
      return "Never checked" unless run
      return "Stalled" if run.active_key && run.updated_at < ::Seo::Diagnostics::STALL_AFTER.ago
      return "Stale" if run.status == "completed" && (run.generation != @site.seo_generation || run.finished_at < 7.days.ago)

      case run.status
      when "pending" then "Queued"
      when "completed" then run.summary.fetch("codes").empty? ? "Clean" : "Findings"
      else run.status.capitalize
      end
    end

    def seo_cache_scope(cache)
      case cache
      when ActiveSupport::Cache::MemoryStore then "Per process"
      when ActiveSupport::Cache::NullStore then "Uncached"
      when ActiveSupport::Cache::FileStore then "Filesystem; sharing depends on the configured mount"
      else "Operator-configured; check whether the store is shared"
      end
    end

    def seo_finding_action(code)
      case code
      when "canonical_mismatch", "noindex_or_missing_robots"
        link_to "Check the canonical origin and indexing settings", admin_settings_path
      when "sitemap_inventory_mismatch", "sitemap_lastmod_mismatch", "target_inventory_mismatch"
        link_to "Review the sitemap comparison", admin_seo_sitemap_path
      when "authority_or_policy_changed"
        link_to "Review the current indexing policy", admin_seo_indexability_path
      when "queue_unavailable", "execution_unavailable", "run_deadline", "stalled_run_replaced"
        link_to "Check the worker and retry when ready", admin_readiness_path
      when "http_status", "redirected_inventory_url"
        link_to "Check public routes and redirects", admin_seo_indexability_path
      end
    end
  end
end
