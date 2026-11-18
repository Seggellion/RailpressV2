xml.instruct!
xml.rss(version: "2.0") do
  xml.channel do
    xml.title @site.title
    xml.link @site.canonical_origin + "/blog"
    xml.description @site.tagline
    @posts.each do |content|
      item = ContentPresenter.new(content)
      xml.item do
        xml.title item.title
        xml.link @site.canonical_origin + item.path
        xml.guid @site.canonical_origin + item.path
        xml.description item.excerpt
        xml.pubDate content.published_at.rfc2822
      end
    end
  end
end
