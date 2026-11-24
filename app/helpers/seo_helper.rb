module SeoHelper
  def seo_head(policy)
    nodes = [ tag.title(policy.title), tag.meta(name: "robots", content: policy.robots) ]
    nodes << tag.meta(name: "description", content: policy.description) if policy.description.present?
    if policy.canonical
      nodes << tag.link(rel: "canonical", href: policy.canonical)
      nodes << tag.meta(property: "og:url", content: policy.canonical)
    end
    nodes << tag.meta(property: "og:title", content: policy.title)
    nodes << tag.meta(property: "og:description", content: policy.description) if policy.description.present?
    nodes << tag.meta(property: "og:type", content: policy.kind == "Post" ? "article" : "website")
    if policy.canonical
      nodes << tag.meta(property: "og:site_name", content: policy.site.title)
      nodes << tag.meta(name: "twitter:card", content: policy.social_image ? "summary_large_image" : "summary")
      nodes << tag.meta(name: "twitter:title", content: policy.title)
      nodes << tag.meta(name: "twitter:description", content: policy.description) if policy.description.present?
    end
    if (image = policy.social_image)
      nodes << tag.meta(property: "og:image", content: image.url)
      nodes << tag.meta(property: "og:image:alt", content: image.alt)
      nodes << tag.meta(property: "og:image:width", content: image.width) if image.width
      nodes << tag.meta(property: "og:image:height", content: image.height) if image.height
      nodes << tag.meta(name: "twitter:image", content: image.url)
      nodes << tag.meta(name: "twitter:image:alt", content: image.alt)
    end
    graph = Seo::StructuredData.call(policy)
    nodes << tag.script(raw(json_escape(JSON.generate(graph))), type: "application/ld+json") if graph
    safe_join(nodes, "\n")
  end
end
