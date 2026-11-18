# frozen_string_literal: true

require_relative "page_path_contract"

module Railpress
  module ContentRoutes
    RESERVED = %w[admin setup up login logout password blog category tag preview media search assets rails sitemap feed robots health api].freeze
    module_function
    def slug(value)
      I18n.transliterate(value.to_s.unicode_normalize(:nfc)).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end
    def key(value)
      Digest::SHA256.hexdigest(slug(value))
    end
    # Pages may use up to three URL segments. Existing flat keys stay identical;
    # Post and taxonomy slugs retain their original single-segment contract.
    def content_slug(type, value)
      return slug(value) unless type == "Page"
      PagePathContract.normalize(value) { |part| slug(part) }
    end
    def content_key(type, value)
      Digest::SHA256.hexdigest(content_slug(type, value))
    end
    def reserved_content_slug?(type, value)
      parts = value.to_s.split("/")
      RESERVED.include?(parts.first) || (type == "Page" && parts.length > 1 && %w[theme-assets theme-media].include?(parts.first))
    end
    def public_path(content, site)
      return "/" if site.home_mode == "static" && site.homepage_content_id == content.id && content.is_a?(Page)
      path(content.type, content.slug)
    end
    def path(type, slug)
      type == "Post" ? "/blog/#{slug}" : "/#{slug}"
    end
  end
end
