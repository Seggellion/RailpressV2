module Seo
  class Policy
    SiteSnapshot = Data.define(:title, :canonical_origin, :organization_name, :home_mode, :homepage_content_id, :locale)
    attr_reader :site, :family, :canonical, :indexability, :title, :description, :data,
      :content_id, :kind, :published_at, :modified_at, :social_image, :page
    def self.visible?(content)
      content&.publicly_visible?
    end
    def self.decision(site:, family:, visible: true, nonempty: true, query: {})
      return Indexability.excluded(reason: "unknown_route") unless RouteRegistry::FAMILIES.include?(family) && family != :not_found
      return Indexability.noindex(reason: "hidden_or_empty") unless visible && nonempty
      return Indexability.noindex(reason: "site_indexing_disabled") unless site.indexing_enabled?
      return Indexability.noindex(reason: "operator_indexing_disabled") if ENV["RAILPRESS_SEO_INDEXING"] == "disabled"
      return Indexability.noindex(reason: "search_results") if family == :search
      return Indexability.noindex(reason: "query_variant") if query.key?("page") && !%i[blog category tag search].include?(family)
      return Indexability.noindex(reason: "query_variant") unless (query.keys.map(&:to_s)-[ "page" ]).empty?
      Indexability.index(reason: "public_canonical_route")
    end
    def initialize(site:, family:, path: nil, content: nil, page: 1, nonempty: true, query: {}, title: nil, preview: false)
      values = SiteSnapshot.members.to_h do |field|
        value = site.public_send(field)
        [ field, value.is_a?(String) ? value.dup.freeze : value ]
      end
      @site = SiteSnapshot.new(**values)
      @family, @page = family, page
      publicly_visible = self.class.visible?(content)
      @data = publicly_visible ? content.published_snapshot.to_h.deep_dup : {}
      deep_freeze(@data)
      @content_id, @kind = content&.id, content&.type
      @published_at, @modified_at = content&.first_published_at, content&.public_updated_at
      visible = !%i[page post].include?(family) || publicly_visible
      @indexability = self.class.decision(site: site, family: family, visible: visible, nonempty: nonempty, query: query)
      @indexability = Indexability.noindex(reason: "theme_preview") if preview
      @canonical = !preview && path && family != :not_found && visible ? CanonicalUrl.new(origin: site.canonical_origin).call(path, query: canonical_query(query)) : nil
      @title = [ data["meta_title"].presence || data["title"].presence || title.presence || site.title, site.title ].uniq.join(" · ").freeze
      @description = (data["meta_description"].presence || data["excerpt"].presence || body_summary || site.tagline).to_s.freeze
      @social_image = Seo::SocialImage.call(content: content, snapshot: data, origin: site.canonical_origin) if @canonical && publicly_visible
      @canonical&.freeze
      @kind = @kind&.dup&.freeze
      @published_at = @published_at&.dup&.freeze
      @modified_at = @modified_at&.dup&.freeze
      freeze
    end
    def robots = indexability.robots
    private
    def body_summary
      plain = ApplicationController.helpers.strip_tags(data["body"].to_s).squish
      plain.presence&.truncate(160, separator: /\s/)
    end

    def canonical_query(query)
      result = {}
      result["q"] = query["q"].to_s if family == :search && query["q"].present?
      result["page"] = page if page > 1
      result
    end
    def deep_freeze(value)
      value.each { |key, item| key.freeze; deep_freeze(item) } if value.is_a?(Hash)
      value.each { |item| deep_freeze(item) } if value.is_a?(Array)
      value.freeze
    end
  end
end
