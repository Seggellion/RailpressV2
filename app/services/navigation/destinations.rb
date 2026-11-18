module Navigation
  module Destinations
    module_function
    def resolve(row, site, at: Time.current)
      case row["kind"]
      when "Page", "Post"
        content = Content.publicly_visible_at(at).find_by(id: row["content_id"], type: row["kind"])
        content && Seo::RouteRegistry.content_path(content, site)
      when "Term"
        term = Term.includes(:taxonomy).find_by(id: row["term_id"])
        term && public_term?(term, at) && "/#{term.taxonomy.kind}/#{term.slug}"
      when "Custom"
        url = SafeUrl.validate!(row["url"])
        uri = URI.parse(url)
        origin = URI.parse(site.canonical_origin)
        local = !uri.host || (uri.scheme == origin.scheme && uri.host == origin.host && uri.port == origin.port)
        return url unless local
        path = uri.path
        public_path?(path, site, at) ? (uri.host ? uri.request_uri + (uri.fragment ? "##{uri.fragment}" : "") : url) : nil
      end
    rescue Mutation::Invalid, URI::InvalidURIError
      nil
    end
    def public_term?(term, at)
      Content.publicly_visible_at(at).joins(:content_terms).where(type: "Post", content_terms: { term_id: term.id, stage: "live" }).exists?
    end
    def public_path?(path, site, at)
      return true if [ "/", Seo::RouteRegistry.blog_path(site), "/blog", "/search" ].include?(path)
      if (match = path.match(%r{\A/(category|tag)/([a-z0-9-]+)\z}))
        term = Term.joins(:taxonomy).find_by(slug: match[2], taxonomies: { kind: match[1] })
        return term && public_term?(term, at)
      end
      content = if path.start_with?("/blog/")
        Post.publicly_visible_at(at).find_by(slug: path.delete_prefix("/blog/"))
      elsif Seo::RouteRegistry.redirect_source?(path)
        Page.publicly_visible_at(at).find_by(slug: path.delete_prefix("/"))
      end
      content && Seo::RouteRegistry.content_path(content, site) == path
    end
  end
end
