module Seo
  module Invalidation
    module_function
    def bump!
      Site.where(singleton_key: 1).update_all([ "seo_generation = seo_generation + 1, seo_changed_at = ?", Time.current ])
    end
    def after_commit!
      cache = Rails.cache
      # Cross-process correctness uses the committed DB generation. Only the
      # native in-process store is pruned synchronously; never call a remote
      # cache backend on the publication path.
      cache.delete_matched("seo/sitemap/*") if cache.is_a?(ActiveSupport::Cache::MemoryStore)
    rescue StandardError, NotImplementedError
      Rails.logger.warn("SEO cache invalidation unavailable; durable generation remains authoritative")
    end
  end
end
