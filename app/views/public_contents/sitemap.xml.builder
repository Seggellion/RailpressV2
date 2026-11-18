xml.instruct!
xml.urlset(xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9") do
  @inventory.each do |content|
    xml.url do
      xml.loc @site.canonical_origin + Railpress::ContentRoutes.public_path(content, @site)
      xml.lastmod content.published_at.iso8601
    end
  end
end
