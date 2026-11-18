module Seo
  class UrlInventory
    class TooLarge < StandardError; end
    Entry = Data.define(:url, :family, :last_modified)
    MAX_URLS = 50_000
    def self.call(site:, at: Time.current)
      return [] unless Policy.decision(site: site, family: :home).indexable?
      canonical = CanonicalUrl.new(origin: site.canonical_origin)
      eligible = Content.publicly_visible_at(at)
      rows = eligible.select(:id, :type, :slug, :published_at, :public_updated_at).order(:id).limit(MAX_URLS+1).to_a
      raise TooLarge if rows.length > MAX_URLS
      entries = rows.map do |item|
        Entry.new(url: canonical.call(RouteRegistry.content_path(item, site)), family: item.type.downcase, last_modified: item.public_updated_at || item.published_at)
      end
      posts = rows.select { |item| item.type == "Post" }
      if posts.any?
        entries << Entry.new(url: canonical.call(RouteRegistry.blog_path(site)), family: "blog", last_modified: posts.map { |item| item.public_updated_at || item.published_at }.max)
        scope = ContentTerm.where(stage: "live", content_id: eligible.where(type: "Post").select(:id))
        times = scope.joins(:content).group(:term_id).maximum("contents.public_updated_at")
        Term.where(id: scope.select(:term_id)).includes(:taxonomy).limit(MAX_URLS+1).each do |term|
          entries << Entry.new(url: canonical.call("/#{term.taxonomy.kind}/#{term.slug}"), family: term.taxonomy.kind, last_modified: [ times[term.id]&.to_time, term.updated_at ].compact.max)
        end
      end
      entries = entries.uniq(&:url).sort_by(&:url)
      raise TooLarge if entries.length > MAX_URLS
      entries.freeze
    end
  end
end
