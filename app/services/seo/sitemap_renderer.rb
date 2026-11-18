# frozen_string_literal: true

# Adapted from UltimaCraft a6e17605689442a91e697eae0584a0c2bf84f4bf; MIT (c) 2024-2026 Dustin Hill.
# See THIRD_PARTY_NOTICES.md. Railpress uses approved public modification times.

require "nokogiri"

module Seo
  class SitemapRenderer
    NAMESPACE = "http://www.sitemaps.org/schemas/sitemap/0.9"

    def call(entries)
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.urlset(xmlns: NAMESPACE) do
          entries.each do |entry|
            xml.url do
              xml.loc(entry.url)
              xml.lastmod(entry.last_modified.utc.iso8601(6)) if entry.last_modified
            end
          end
        end
      end.to_xml
    end
  end
end
