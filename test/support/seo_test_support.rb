require_relative "media_test_support"
module SeoTestSupport
  extend ActiveSupport::Concern
  include MediaTestSupport
  include ActiveJob::TestHelper
  included do
    setup do
      Site.first.update!(indexing_enabled: true)
      clear_enqueued_jobs
    end
  end
  def site = Site.find_by!(singleton_key: 1)
  def sitemap_urls
    Nokogiri::XML(Seo::SitemapCache.fetch(site: site).xml).xpath("//*[local-name()='loc']").map(&:text)
  end
  def observed_head
    html = Nokogiri::HTML(response.body)
    { "status"=>response.status, "canonical"=>html.css('link[rel="canonical"]').map { |node| node["href"] },
      "robots"=>html.css('meta[name="robots"]').map { |node| node["content"] }, "header"=>response.headers["X-Robots-Tag"],
      "schema"=>html.css('script[type="application/ld+json"]').flat_map { |node| JSON.parse(node.text).fetch("@graph").map { |item| item["@type"] } } }
  end
  def public_content(slug: "seo-public", **attributes)
    item=draft(slug: slug, **attributes)
    change(item, "publish")
  end
end
