require Rails.root.join("lib/railpress/theme_renderer")
# Frozen presentation contract; persistence and menu management belong to M08.
module Themes
  module Navigation
    Item = Railpress::ThemeRenderer::NavigationItem
    Slots = Railpress::ThemeRenderer::NavigationSlots
    module_function
    def item(label:, url:, children: [])
      raise ArgumentError, "navigation_label" unless label.is_a?(String) && label.valid_encoding? && label.length.between?(1, 120)
      raise ArgumentError, "navigation_url" unless url.is_a?(String) && url.length <= 2048 && url.start_with?("/") && !url.start_with?("//") && !url.match?(/[\\\x00-\x20]/)
      Item.new(label: label.dup.freeze, url: url.dup.freeze, children: children.dup.freeze)
    end
    def slots(primary:, footer: [], mobile: primary, documentation: [])
      count = 0
      check = lambda do |items, depth|
        raise ArgumentError, "navigation_bounds" unless items.is_a?(Array) && depth <= 3
        items.each do |entry|
          count += 1
          raise ArgumentError, "navigation_item" unless entry.is_a?(Item) && entry.frozen? && entry.children.frozen?
          link(label: entry.label, url: entry.url, children: entry.children)
          check.call(entry.children, depth + 1) unless entry.children.empty?
        end
      end
      [ primary, mobile, footer, documentation ].each { |items| check.call(items, 1) }
      raise ArgumentError, "navigation_bounds" if count > 120
      Slots.new(primary: primary.dup.freeze, mobile: mobile.dup.freeze, footer: footer.dup.freeze, documentation: documentation.dup.freeze)
    end
    def link(label:, url:, children: [])
      ::Navigation::SafeUrl.validate!(url)
      raise ArgumentError, "navigation_label" unless label.is_a?(String) && label.valid_encoding? && label.length.between?(1, 120)
      Item.new(label: label.dup.freeze, url: url.dup.freeze, children: children.dup.freeze)
    rescue ::Navigation::Mutation::Invalid
      raise ArgumentError, "navigation_url"
    end
    def call(site:)
      fallback(site)
    end
    def fallback(site)
      slots(primary: [ item(label: "Home", url: "/"), item(label: "Journal", url: Seo::RouteRegistry.blog_path(site)), item(label: "Search", url: "/search") ].uniq { |entry| entry.url })
    end
  end
end
