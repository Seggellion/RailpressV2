require "action_view"
require "active_support/inflector"
require "nokogiri"
require "uri"
require_relative "theme_package"
module Railpress
  module ThemeRenderer
    class Invalid < StandardError; end
    Site = Data.define(:title, :tagline, :locale, :home_url, :blog_url, :search_url)
    Content = Data.define(:title, :excerpt, :url, :body_html, :blocks_html, :featured_html, :published_at)
    NavigationItem = Data.define(:label, :url, :children)
    NavigationSlots = Data.define(:primary, :mobile, :footer, :documentation)
    Context = Data.define(:api_version, :family, :site, :content, :items, :query, :archive_title, :pagination, :options, :navigation, :recent_items)
    Output = Data.define(:body, :navigation, :footer)
    BASE = ActionView::Base.with_empty_template_cache
    class View < BASE
      def initialize(bundle, context)
        super(ActionView::LookupContext.new([]), {}, nil)
        @bundle, @context, @depth = bundle, context, 0
      end
      def theme = @context
      def render(*) = raise(Invalid, "resolver_lookup_forbidden")
      def theme_component(name)
        raise Invalid, "unknown_component" unless %w[navigation pagination media footer].include?(name)
        family(name)
      end
      def theme_asset_url(name)
        asset = @bundle.manifest.fetch("assets").fetch(name.to_s) { raise Invalid, "unknown_theme_asset" }
        "/theme-assets/#{@bundle.manifest.fetch('id')}/#{@bundle.manifest.fetch('version')}/#{@bundle.digest}/#{asset.fetch('file').delete_prefix('assets/')}"
      end
      def theme_artwork? = @bundle.manifest.fetch("options").key?("artwork_styles") && theme.options.fetch("artwork_style", "editorial") == "editorial"
      def theme_body_with_section_ids
        body = Nokogiri::HTML5.fragment(theme.content.body_html)
        reserved = body.css("[id]").to_h { |element| [ element["id"], true ] }
        body.css("h2, h3").each do |heading|
          label = ActiveSupport::Inflector.parameterize(heading.text)[0, 70]
          next if label.empty?
          base = "section-#{label}"
          id = base
          offset = 1
          while reserved[id]
            offset += 1
            id = "#{base}-#{offset}"
          end
          reserved[id] = true
          heading["id"] = id
        end
        body.to_html.html_safe
      end
      def theme_picture(name, loading: "lazy", sizes: "100vw")
        raise Invalid, "picture_options" unless name.to_s.match?(/\A[a-z_]{1,20}\z/) && %w[lazy eager].include?(loading)
        source = [ 360, 768, 1024 ].map { |width| "#{theme_asset_url("#{name}_#{width}")} #{width}w" }.join(", ")
        content_tag(:picture, class: "dusk-art-image", "aria-hidden": "true") do
          tag.source(type: "image/webp", srcset: source, sizes: sizes) +
            tag.img(src: theme_asset_url("#{name}_png"), alt: "", width: 360, height: 240, loading: loading, decoding: "async")
        end
      end
      def family(name)
        raise Invalid, "recursive_component" if @depth >= 5
        @depth += 1
        source = @bundle.files.fetch("templates/#{name}.html.erb").dup.force_encoding("UTF-8")
        ActionView::Base.instance_method(:render).bind_call(self, inline: source, type: :erb, locals: {})
      ensure
        @depth -= 1
      end
    end
    module_function
    def guard!(html, bundle: nil)
      raise Invalid, "output_bounds" unless html.bytesize <= 262_144 && html.valid_encoding?
      fragment = Nokogiri::HTML5.fragment(html)
      raise Invalid, "protected_markup" if fragment.css("html,head,body,main,title,meta,base,link,style,script,iframe,object,embed,template").any? || html.match?(/<\/?(?:html|head|body|main)\b/i)
      fragment.traverse do |node|
        next unless node.element?
        tags = %w[header footer section article h1 h2 h3 h4 h5 h6 p br strong em u ul ol li blockquote pre code a hr nav figure figcaption img picture source time form label input button div span table thead tbody tfoot tr th td caption details summary address dl dt dd]
        raise Invalid, "unknown_markup" unless tags.include?(node.name)
        raise Invalid, "protected_id" if node["id"] == "main"
        raise Invalid, "source_context" if node.name == "source" && (node.parent.name != "picture" || node["type"] != "image/webp" || !node["srcset"])
        node.attribute_nodes.each do |attribute|
          allowed = %w[id class role href src srcset sizes alt width height loading decoding rel type name value action method for datetime title colspan rowspan scope open]
          raise Invalid, "unsafe_attribute" unless allowed.include?(attribute.name) || attribute.name.match?(/\A(?:aria|data)-[a-z0-9_-]+\z/)
          if attribute.name == "srcset"
            raise Invalid, "srcset_context" unless bundle && %w[source img].include?(node.name)
            allowed_sources = bundle.manifest.fetch("assets").values.select { |asset| asset["content_type"] == "image/webp" }.map do |asset|
              "/theme-assets/#{bundle.manifest.fetch('id')}/#{bundle.manifest.fetch('version')}/#{bundle.digest}/#{asset.fetch('file').delete_prefix('assets/')}"
            end
            candidates = attribute.value.split(",", -1)
            widths = []
            raise Invalid, "srcset_bounds" unless candidates.length.between?(1, 4) && attribute.value.bytesize <= 1024
            candidates.each do |candidate|
              url, width, extra = candidate.strip.split(/\s+/)
              raise Invalid, "unsafe_srcset" unless extra.nil? && allowed_sources.include?(url) && width&.match?(/\A(?:360|768|1024)w\z/)
              widths << width.to_i
            end
            raise Invalid, "srcset_order" unless widths == widths.uniq.sort
          elsif attribute.name == "sizes"
            raise Invalid, "unsafe_sizes" unless %w[source img].include?(node.name) && [ "100vw", "(min-width: 58rem) 40vw, 100vw", "(min-width: 58rem) 24vw, 100vw" ].include?(attribute.value)
          end
          if %w[href src action formaction].include?(attribute.name)
            value = attribute.value
            raise Invalid, "unsafe_url" if value.start_with?("//") || value.match?(/[\\\x00-\x20]/)
            if node.name == "a" && attribute.name == "href"
              uri = URI.parse(value)
              raise Invalid, "unsafe_link" unless (uri.scheme.nil? && uri.host.nil?) || (%w[http https mailto tel ftp].include?(uri.scheme) && !uri.userinfo)
            else
              raise Invalid, "unsafe_resource_url" unless value.start_with?("/", "#")
            end
          end
        end
        raise Invalid, "protected_form" if node.name == "form" && !(node["action"] == "/search" && node["method"].to_s.downcase == "get")
      end
      html.freeze
    end
    def render(bundle, context)
      raise Invalid, "family" unless ThemePackage::FAMILIES.include?(context.family)
      view = View.new(bundle, context)
      Output.new(body: guard!(view.family(context.family).to_s, bundle: bundle), navigation: guard!(view.family("navigation").to_s, bundle: bundle), footer: guard!(view.family("footer").to_s, bundle: bundle))
    end
    def fixture_context(family, options = {})
      content = Content.new(title: "Synthetic page".freeze, excerpt: "Safe excerpt".freeze, url: "/sample".freeze, body_html: "<p>Safe body</p>".html_safe.freeze, blocks_html: "".html_safe.freeze, featured_html: "".html_safe.freeze, published_at: "2026-01-01".freeze)
      links = [ NavigationItem.new(label: "Home".freeze, url: "/".freeze, children: [].freeze), NavigationItem.new(label: "Journal".freeze, url: "/blog".freeze, children: [].freeze) ].freeze
      navigation = NavigationSlots.new(primary: links, mobile: links, footer: [].freeze, documentation: [].freeze)
      Context.new(api_version: 1, family: family.freeze, site: Site.new(title: "Synthetic site".freeze, tagline: "Local qualification".freeze, locale: "en".freeze, home_url: "/".freeze, blog_url: "/blog".freeze, search_url: "/search".freeze), content: content, items: [ content ].freeze, query: "sample".freeze, archive_title: "Blog".freeze, pagination: ThemePackage.freeze_tree({ "previous" => "/blog", "next" => "/blog?page=2" }), options: ThemePackage.freeze_tree(options), navigation: navigation, recent_items: [ content ].freeze)
    end
  end
end
