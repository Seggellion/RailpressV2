module Seo
  class CanonicalUrl
    def initialize(origin:)
      @origin = SiteOrigin.new(origin).to_s
    end
    def call(path, query: {})
      raise SiteOrigin::Invalid, "Invalid core path" unless path.is_a?(String) && (path.match?(/\A\/[a-z0-9\/-]*\z/) || %w[/sitemap.xml /robots.txt /feed.xml].include?(path)) && !path.start_with?("//") && !path.include?("//")
      raise SiteOrigin::Invalid, "Invalid canonical query" unless (query.keys.map(&:to_s)-%w[page q]).empty?
      encoded = URI.encode_www_form(query)
      @origin + path + (encoded.empty? ? "" : "?#{encoded}")
    end
  end
end
