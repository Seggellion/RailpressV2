# frozen_string_literal: true

class ContentPresenter
  attr_reader :data, :path, :published_at
  def initialize(content, snapshot: nil, path: nil, preview_id: nil)
    @data = (snapshot || content.published_snapshot).deep_dup.freeze
    @path = path || Railpress::ContentRoutes.path(content.type, @data.fetch("slug"))
    @published_at = content.published_at
    @media_renderer = ContentBlocks::Renderer.new(details: @data["media_details"], context: { content_id: content.id, preview_id: preview_id })
  end
  def title
    data.fetch("title")
  end
  def body_html
    ApplicationController.helpers.sanitize(data.fetch("body"), tags: Editorial::RichText::TAGS, attributes: Editorial::RichText::ATTRIBUTES)
  end
  def blocks_html
    @media_renderer.render(data["blocks"])
  end
  def featured_html
    @media_renderer.image(data["featured_media_id"])
  end
  def excerpt
    data["excerpt"].to_s
  end
  def meta_title
    data["meta_title"].presence || title
  end
  def meta_description
    data["meta_description"].presence || excerpt
  end
end
