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
    graph = Seo::StructuredData.call(policy)
    nodes << tag.script(raw(json_escape(JSON.generate(graph))), type: "application/ld+json") if graph
    safe_join(nodes, "\n")
  end
end
