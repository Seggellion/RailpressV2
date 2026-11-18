require Rails.root.join("lib/railpress/theme_renderer")
module Themes
  module Context
    module_function
    def content(presenter)
      return unless presenter
      Railpress::ThemeRenderer::Content.new(title: presenter.title.dup.freeze, excerpt: presenter.excerpt.dup.freeze, url: presenter.path.dup.freeze, body_html: presenter.body_html.freeze, blocks_html: presenter.blocks_html.freeze, featured_html: presenter.featured_html.freeze, published_at: presenter.published_at&.iso8601&.freeze)
    end
    def build(site:, family:, presenter:, presenters:, query:, title:, page:, more:, path:, options:, navigation: nil)
      next_url = more ? "#{path}?#{ { q: query.presence, page: page + 1 }.compact.to_query }" : nil
      previous_url = page > 1 ? "#{path}?#{ { q: query.presence, page: page - 1 }.compact.to_query }" : nil
      Railpress::ThemeRenderer::Context.new(api_version: 1, family: family.freeze,
        site: Railpress::ThemeRenderer::Site.new(title: site.title.dup.freeze, tagline: site.tagline.dup.freeze, locale: site.locale.dup.freeze, home_url: "/".freeze, blog_url: Seo::RouteRegistry.blog_path(site).freeze, search_url: "/search".freeze),
        content: content(presenter), items: presenters.map { |item| content(item) }.freeze, query: query.to_s.dup.freeze, archive_title: title.to_s.dup.freeze,
        pagination: Railpress::ThemePackage.freeze_tree({ "previous" => previous_url, "next" => next_url }), options: Railpress::ThemePackage.freeze_tree(options.deep_dup), navigation: navigation || Navigation.call(site: site),
        recent_items: Post.publicly_visible.order(published_at: :desc, id: :desc).limit(3).map { |item| content(ContentPresenter.new(item)) }.freeze)
    end
  end
end
