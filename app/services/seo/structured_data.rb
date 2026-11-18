module Seo
  module StructuredData
    module_function
    def call(policy)
      return unless policy.indexability.indexable? && policy.canonical
      site = policy.site
      origin = SiteOrigin.new(site.canonical_origin).to_s
      graph = [
        { "@type" => "WebSite", "@id" => "#{origin}/#website", "url" => "#{origin}/", "name" => site.title },
        { "@type" => "WebPage", "@id" => "#{policy.canonical}#webpage", "url" => policy.canonical, "name" => policy.title,
          "description" => policy.description, "isPartOf" => { "@id" => "#{origin}/#website" } }
      ]
      if site.organization_name.present?
        graph << { "@type" => "Organization", "@id" => "#{origin}/#organization", "name" => site.organization_name, "url" => "#{origin}/" }
        graph.first["publisher"] = { "@id" => "#{origin}/#organization" }
      end
      if policy.kind == "Post" && policy.published_at
        article = { "@type" => "BlogPosting", "@id" => "#{policy.canonical}#article", "url" => policy.canonical,
          "headline" => policy.title, "datePublished" => policy.published_at.utc.iso8601(6),
          "mainEntityOfPage" => { "@id" => "#{policy.canonical}#webpage" } }
        article["dateModified"] = policy.modified_at.utc.iso8601(6) if policy.modified_at
        article["author"] = { "@type" => "Person", "name" => policy.author_name } if policy.author_name.present?
        graph << article
      end
      crumbs = [ { "name" => site.title, "item" => "#{origin}/" } ]
      crumbs << { "name" => "Blog", "item" => CanonicalUrl.new(origin: origin).call(RouteRegistry.blog_path(site)) } if policy.kind == "Post"
      crumbs << { "name" => policy.title, "item" => policy.canonical }
      crumbs = crumbs.uniq { |crumb| crumb["item"] }
      if crumbs.length > 1
        graph << { "@type" => "BreadcrumbList", "itemListElement" => crumbs.each_with_index.map { |crumb, index| crumb.merge("@type" => "ListItem", "position" => index+1) } }
      end
      { "@context" => "https://schema.org", "@graph" => graph }
    end
  end
end
