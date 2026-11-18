module Seo
  module RouteRegistry
    FAMILIES = %i[home page post blog category tag search not_found].freeze
    module_function
    def content_path(content, site)
      return "/" if content.type == "Page" && site.home_mode == "static" && site.homepage_content_id == content.id
      Railpress::ContentRoutes.path(content.type, content.slug)
    end
    def blog_path(site) = site.home_mode == "blog" ? "/" : "/blog"
    def redirect_source?(path)
      return false unless path.is_a?(String) && path.match?(/\A\/[a-z0-9]+(?:-[a-z0-9]+)*(?:\/[a-z0-9]+(?:-[a-z0-9]+)*){0,2}\z/)
      parts = path.delete_prefix("/").split("/")
      return parts.length == 2 if parts.first == "blog"
      !Railpress::ContentRoutes.reserved_content_slug?("Page", path.delete_prefix("/"))
    end
  end
end
