# frozen_string_literal: true

module ContentBlocks
  class Renderer
    def initialize(details:, context:)
      @details, @context = details.to_h, context
      @h = ApplicationController.helpers
    end
    def render(blocks)
      @h.safe_join(ContentBlocks::Schema.normalize(blocks).map { |block| render_block(block) })
    end
    def image(id, caption = nil)
      return "".html_safe unless id
      detail = @details[id.to_s] || {}
      asset = MediaAsset.ready.find_by(id: id)
      alt = detail["decorative"] ? "" : detail.fetch("alt_text", "Image unavailable")
      unless asset && detail["sha256"] == asset.sha256 && MediaLibrary::Delivery.exists?(asset)
        return @h.tag.span("Image unavailable: #{alt}", class: "media-unavailable", role: "img", aria: { label: alt.presence || "Decorative image unavailable" })
      end
      source = if @context[:preview_id]
        "/preview/#{@context.fetch(:preview_id)}/media/#{asset.public_id}/display"
      else
        "/media/#{@context.fetch(:content_id)}/#{asset.public_id}/display"
      end
      picture = @h.tag.img(src: source, alt: alt, width: detail["width"], height: detail["height"], loading: "lazy", decoding: "async")
      description = caption.presence || detail["caption"]
      attribution = detail["attribution"]
      @h.tag.figure do
        @h.safe_join([ picture, description.present? ? @h.tag.figcaption(description) : nil, attribution.present? ? @h.tag.p(attribution, class: "media-attribution") : nil ].compact)
      end
    end
    private
    def render_block(block)
      case block["type"]
      when "heading" then @h.content_tag("h#{block.fetch('level')}", block["text"])
      when "paragraph" then @h.sanitize(block["html"], tags: Editorial::RichText::TAGS, attributes: Editorial::RichText::ATTRIBUTES)
      when "external_media"
        @h.tag.section(class: "external-media-disclosure", aria: { label: "External media" }) do
          @h.safe_join([ @h.tag.h2(block["heading"].presence || "External media"),
            @h.tag.p("Nothing is embedded or preloaded. Following this link opens another website, which receives your request and may use cookies or tracking under its own policy."),
            block["url"].present? ? @h.link_to("Open external media", block["url"], rel: "nofollow noopener noreferrer") : @h.tag.p("No external media destination is configured.") ])
        end
      when "image" then image(block["media_id"], block["caption"])
      when "gallery"
        @h.tag.section(aria: { label: block["caption"].presence || "Image gallery" }, class: "content-gallery") { @h.safe_join(block["media_ids"].map { |id| image(id) }) }
      when "hero", "call_to_action"
        @h.tag.section(class: "content-#{block['type']}") do
          @h.safe_join([ @h.tag.h2(block["heading"]), @h.tag.p(block["text"]), image(block["media_id"]), block["url"].present? ? @h.link_to(block["label"].presence || "Learn more", block["url"], rel: "noopener") : nil ].compact)
        end
      when "features"
        @h.tag.section(aria: { label: "Services and features" }) do
          @h.safe_join(block["items"].map { |item| @h.tag.article { @h.safe_join([ @h.tag.h3(item["heading"]), @h.tag.p(item["text"]) ]) } })
        end
      when "testimonial"
        @h.tag.figure { @h.safe_join([ @h.tag.blockquote(block["quote"]), @h.tag.figcaption(block["attribution"]) ]) }
      when "faq"
        @h.tag.section(aria: { label: "Frequently asked questions" }) do
          @h.safe_join(block["items"].map { |item| @h.tag.details { @h.safe_join([ @h.tag.summary(item["question"]), @h.tag.p(item["answer"]) ]) } })
        end
      when "contact"
        @h.tag.section { @h.safe_join([ @h.tag.h2(block["heading"]), @h.tag.address { @h.safe_join(%w[address email phone].map { |key| @h.tag.p(block[key]) }) } ]) }
      end
    end
  end
end
