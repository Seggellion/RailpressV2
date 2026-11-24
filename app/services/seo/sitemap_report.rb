# frozen_string_literal: true

module Seo
  class SitemapReport
    NAMESPACES = { "s" => SitemapRenderer::NAMESPACE }.freeze
    attr_reader :entries, :payload, :rendered_count, :missing_count, :unexpected_count, :duplicate_count, :lastmod_count, :lastmod_mismatches

    def initialize(site:, entries: UrlInventory.call(site: site), payload: SitemapCache.fetch(site: site))
      @entries, @payload = entries, payload
      document = Nokogiri::XML(payload.xml) { |config| config.strict.nonet }
      @valid_root = document.at_xpath("/s:urlset", NAMESPACES).present?
      nodes = document.xpath("/s:urlset/s:url", NAMESPACES)
      rendered = nodes.map { |node| [ node.at_xpath("./s:loc", NAMESPACES)&.text, node.at_xpath("./s:lastmod", NAMESPACES)&.text ] }
      expected = entries.to_h { |entry| [ entry.url, entry.last_modified&.utc&.iso8601(6) ] }
      urls = rendered.map(&:first)
      @rendered_count = urls.size
      @missing_count = (expected.keys - urls).size
      @unexpected_count = (urls - expected.keys).size
      @duplicate_count = urls.size - urls.uniq.size
      @lastmod_count = rendered.count { |_, date| date.present? }
      @lastmod_mismatches = rendered.count { |url, date| expected.key?(url) && expected[url] != date }
    end

    def codes
      [ ("sitemap_inventory_mismatch" if !@valid_root || missing_count.positive? || unexpected_count.positive? || duplicate_count.positive?),
        ("sitemap_lastmod_mismatch" if lastmod_mismatches.positive?) ].compact
    end
  end
end
