# frozen_string_literal: true

class PublicContentsController < ApplicationController
  layout "public_content"
  skip_before_action :require_https
  before_action :load_site
  before_action :public_transport
  rescue_from ActiveRecord::RecordNotFound, ArgumentError, TypeError, ActionController::UnknownFormat do
    not_found
  end
  rescue_from Seo::UrlInventory::TooLarge do
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    render plain: "The sitemap exceeds supported limits. Contact the site operator.", status: :service_unavailable
  end
  def home
    return archive if @site.home_mode == "blog"
    content = Page.publicly_visible.find_by(id: @site.homepage_content_id)
    @presenter = ContentPresenter.new(content, path: "/") if content
    apply_policy(family: content ? :page : :home, path: "/", content: content, nonempty: content.present?)
    render_public(:home)
  end
  def page = show_content(Page)
  def post = show_content(Post)
  def category = archive("category")
  def tag = archive("tag")
  def archive(kind = nil)
    relation = Post.publicly_visible
    @page = page_number
    if kind
      @term = Term.joins(:taxonomy).find_by!(taxonomies: { kind: kind }, slug_key: Railpress::ContentRoutes.key(params[:slug]))
      base = kind == "category" ? category_archive_path(@term.slug) : tag_archive_path(@term.slug)
      return redirect_public(with_page(base)) if params[:slug] != @term.slug
      relation = relation.joins(:content_terms).where(content_terms: { stage: "live", term_id: @term.id })
    else
      base = Seo::RouteRegistry.blog_path(@site)
      return redirect_public(with_page(base)) if request.path == "/blog" && base == "/"
    end
    @presenters, @more = collection(relation)
    raise ActiveRecord::RecordNotFound if @page > 1 && @presenters.empty?
    return redirect_public(base) if params[:page].present? && @page == 1 && request.query_parameters.keys == [ "page" ]
    @archive_path = base
    apply_policy(family: kind ? kind.to_sym : :blog, path: base, page: @page, nonempty: @presenters.any?, title: @term&.name || "Blog")
    render_public(:archive)
  end
  def search
    @page = page_number
    @query = params[:q].to_s.strip
    raise ActiveRecord::RecordNotFound if @query.length > 160 || !@query.valid_encoding?
    pattern = "%#{Content.sanitize_sql_like(@query)}%"
    relation = Content.publicly_visible
    relation = @query.empty? ? Content.none : relation.where("LOWER(public_search_text) LIKE LOWER(?)", pattern)
    @presenters, @more = collection(relation)
    raise ActiveRecord::RecordNotFound if @page > 1 && @presenters.empty?
    @archive_path = "/search"
    apply_policy(family: :search, path: "/search", page: @page, nonempty: @presenters.any?, title: "Search")
    render_public(:search)
  end
  def sitemap
    request.delete_header("HTTP_IF_MODIFIED_SINCE")
    payload = Seo::SitemapCache.fetch(site: @site)
    response.set_header("Cache-Control", "no-cache, must-revalidate")
    response.set_header("Last-Modified", payload.last_modified.httpdate)
    etag = %("#{payload.etag}")
    response.set_header("ETag", etag)
    candidates = request.get_header("HTTP_IF_NONE_MATCH").to_s.split(",").map(&:strip)
    return head :not_modified if candidates.any? { |candidate| [ etag, "W/#{etag}", "*" ].include?(candidate) }
    render body: payload.xml, content_type: "application/xml"
  end
  def robots
    enabled = Seo::Policy.decision(site: @site, family: :home).indexable?
    body = enabled ? "User-agent: *\nAllow: /\nDisallow: /admin\nDisallow: /preview\nSitemap: #{Seo::CanonicalUrl.new(origin: @site.canonical_origin).call('/sitemap.xml')}\n" : "User-agent: *\nDisallow: /\n"
    response.set_header("Cache-Control", "no-cache, must-revalidate")
    render plain: body, content_type: "text/plain"
  end
  def feed
    @posts = Post.publicly_visible.order(published_at: :desc, id: :desc).limit(20)
    render :feed, formats: :xml, layout: false, content_type: "application/rss+xml"
  end
  def not_found
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    if @site
      apply_policy(family: :not_found, title: "Page not found")
      render_public(:not_found, status: :not_found)
    else
      render plain: "Page not found.", status: :not_found
    end
  end
  private
  def core_headers
    Current.reset
    response.set_header("Cache-Control", "no-cache")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    response.set_header("Referrer-Policy", "strict-origin-when-cross-origin")
    response.set_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'none'; frame-ancestors 'none'; base-uri 'none'")
  end
  def load_site
    @site = Site.find_by!(singleton_key: 1)
  end
  def public_transport
    render plain: "HTTPS is required.", status: :upgrade_required if Rails.env.production? && !secure_transport?
  end
  def apply_policy(**options)
    @navigation_preview ||= Navigation::Preview.resolve(actor: current_user, authentication_token: session[:authentication_token], credential: session[:navigation_preview])
    @theme_pair ||= Themes::Selection.call(site: @site, actor: current_user, authentication_token: session[:authentication_token], credential: session[:theme_preview])
    @seo = Seo::Policy.new(site: @site, query: request.query_parameters, preview: @theme_pair&.preview || @navigation_preview.present?, **options)
    response.set_header("Cache-Control", "no-store") if @theme_pair&.preview || @navigation_preview
    response.set_header("X-Robots-Tag", @seo.robots)
  end
  def show_content(kind)
    normalized_slug = Railpress::ContentRoutes.content_slug(kind.name, params[:slug])
    raise ActiveRecord::RecordNotFound if normalized_slug.empty?
    content = kind.publicly_visible.find_by(slug_key: Railpress::ContentRoutes.content_key(kind.name, params[:slug]))
    unless content
      normalized = Railpress::ContentRoutes.path(kind.name, normalized_slug)
      destination = Seo::Redirects.resolve(normalized, @site)
      return redirect_public(destination) if destination
      raise ActiveRecord::RecordNotFound
    end
    path = Seo::RouteRegistry.content_path(content, @site)
    return redirect_public(path) if content.slug != params[:slug] || path == "/"
    @presenter = ContentPresenter.new(content, path: path)
    apply_policy(family: kind == Post ? :post : :page, path: path, content: content)
    render_public(:show)
  end
  def render_public(core_template, status: :ok)
    return render(core_template, status: status) unless @theme_pair
    bundle = Themes::Storage.load(@theme_pair.installation)
    family = case core_template
    when :home then @presenter ? "front" : "home"
    when :show then @seo.kind == "Post" ? "post" : "page"
    when :archive then @presenters.empty? ? "empty" : (@term ? "taxonomy" : "archive")
    when :search then @presenters.empty? ? "empty" : "search"
    else "not_found"
    end
    options = @theme_pair.overlay.options.deep_dup
    @theme_appearance = Themes::Appearance.mode(bundle.manifest, options)
    options["logo_url"] = theme_media_path(@theme_pair.overlay.id, "logo") if @theme_pair.overlay.media_details["logo"]
    options["logo_alt"] = @theme_pair.overlay.media_details.dig("logo", "alt")
    navigation = Navigation::Renderer.call(site: @site, theme_key: @theme_pair.installation.theme_key, declared: bundle.manifest["menu_locations"] || {}, preview: @navigation_preview)
    context = Themes::Context.build(site: @site, family: family, presenter: @presenter, presenters: @presenters || [], query: @query, title: @term&.name || (core_template == :search ? "Search" : "Blog"), page: @page || 1, more: @more, path: @archive_path || "/", options: options, navigation: navigation)
    @theme_output = Railpress::ThemeRenderer.render(bundle, context)
    if [ @theme_output.navigation, @theme_output.footer, @theme_output.body ].any? { |html| Nokogiri::HTML5.fragment(html).at_css("details[data-disclosure]") }
      @public_script_nonce = SecureRandom.base64(24)
      response.set_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'nonce-#{@public_script_nonce}'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
    end
    @theme_stylesheets = bundle.manifest["assets"].values.select { |asset| asset["content_type"] == "text/css" }.map { |asset| theme_asset_path(@theme_pair.installation.theme_key, @theme_pair.installation.version, bundle.digest, asset["file"].delete_prefix("assets/")) }
    @theme_favicon = theme_media_path(@theme_pair.overlay.id, "favicon") if @theme_pair.overlay.media_details["favicon"]
    render html: @theme_output.body.html_safe, layout: "public_content", status: status
  rescue Railpress::ThemePackage::Invalid, Railpress::ThemeRenderer::Invalid, ActionView::Template::Error, StandardError => error
    # No package code runs in this emergency document or protected controllers.
    Rails.logger.error("Theme runtime failure: #{error.class.name}; active identity retained")
    @theme_output = nil
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    response.set_header("Cache-Control", "no-store")
    render html: '<!DOCTYPE html><html lang="en"><head><meta name="robots" content="noindex, nofollow"><title>Site temporarily unavailable</title></head><body><main><h1>Site temporarily unavailable</h1><p>The site operator can recover the selected theme through the protected admin.</p></main></body></html>'.html_safe, layout: false, status: :service_unavailable
  end
  def redirect_public(path)
    raise ArgumentError unless path.start_with?("/") && !path.start_with?("//") && !path.match?(/[\\\r\n]/)
    response.set_header("Location", path)
    head :moved_permanently
  end
  def page_number
    value = Integer(params.fetch(:page, "1").to_s, 10)
    raise ActiveRecord::RecordNotFound unless value.between?(1, 1000)
    value
  end
  def with_page(path) = @page > 1 ? "#{path}?page=#{@page}" : path
  def collection(relation)
    rows = relation.order(published_at: :desc, id: :desc).offset((@page-1)*12).limit(13).to_a
    [ rows.first(12).map { |item| ContentPresenter.new(item) }, rows.length > 12 ]
  end
end
