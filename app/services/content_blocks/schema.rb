# frozen_string_literal: true

module ContentBlocks
  module Schema
    class Invalid < StandardError; end
    TYPES = %w[heading paragraph image gallery hero features testimonial call_to_action faq contact external_media].freeze
    module_function
    def text(value, maximum = 2000)
      string = value.to_s
      raise Invalid, "Block text is too long" if string.length > maximum || !string.valid_encoding?
      string
    end
    def url(value)
      string = text(value, 2048)
      return "" if string.empty?
      return string if string.start_with?("/") && !string.start_with?("//") && !string.match?(/[\\\s\x00-\x1f]/)
      uri = URI.parse(string)
      raise Invalid, "Use a local path or HTTPS link" unless uri.is_a?(URI::HTTPS) && uri.host.present? && !uri.userinfo && !string.match?(/[\x00-\x20]/)
      string
    rescue URI::InvalidURIError
      raise Invalid, "Use a valid link"
    end
    def media_id(value)
      return nil if value.blank?
      number = Integer(value.to_s, 10)
      raise Invalid, "Choose media" unless number.positive?
      number
    rescue ArgumentError
      raise Invalid, "Choose media"
    end
    def array(value)
      return [] if value.nil?
      return value if value.is_a?(Array)
      raise Invalid, "Invalid block collection" unless value.is_a?(Hash) && value.keys.all? { |key| key.to_s.match?(/\A\d+\z/) }
      value.sort_by { |key, _| key.to_i }.map(&:last)
    end
    def normalize(value)
      blocks = array(value)
      raise Invalid, "Use at most 40 blocks" if blocks.length > 40 || JSON.generate(blocks).bytesize > 65_536
      blocks.map do |raw|
        raise Invalid, "Invalid block" unless raw.is_a?(Hash)
        block = raw.stringify_keys
        type = block.fetch("type", "")
        raise Invalid, "Unsupported block" unless TYPES.include?(type)
        result = { "type" => type }
        case type
        when "heading"
          level = Integer(block.fetch("level", 2).to_s, 10)
          raise Invalid unless [ 2, 3, 4 ].include?(level)
          result.merge!("text" => text(block["text"], 200), "level" => level)
        when "paragraph"
          result["html"] = Editorial::RichText.clean(text(block["html"], 10_000))
        when "image"
          result.merge!("media_id" => media_id(block["media_id"]), "caption" => text(block["caption"]))
        when "gallery"
          ids = Array(block["media_ids"]).reject(&:blank?).map { |id| media_id(id) }.uniq
          raise Invalid if ids.length > 12
          result.merge!("media_ids" => ids, "caption" => text(block["caption"]))
        when "external_media"
          result.merge!("heading" => text(block["heading"], 200), "url" => url(block["url"]))
          raise Invalid, "External media requires HTTPS" if result["url"].present? && !result["url"].start_with?("https://")
        when "hero", "call_to_action"
          %w[heading text label].each { |key| result[key] = text(block[key]) }
          result["url"] = url(block["url"])
          result["media_id"] = media_id(block["media_id"]) if type == "hero"
        when "features", "faq"
          items = array(block["items"])
          raise Invalid if items.length > (type == "features" ? 6 : 10)
          fields = type == "features" ? %w[heading text] : %w[question answer]
          result["items"] = items.map { |item| raise Invalid unless item.is_a?(Hash); fields.to_h { |key| [ key, text(item.fetch(key, "")) ] } }
        when "testimonial"
          result.merge!("quote" => text(block["quote"]), "attribution" => text(block["attribution"], 300))
        when "contact"
          %w[heading address email phone].each { |key| result[key] = text(block[key], 1000) }
          raise Invalid, "Invalid email" if result["email"].present? && !URI::MailTo::EMAIL_REGEXP.match?(result["email"])
        end
        result
      end
    rescue ArgumentError, KeyError, TypeError
      raise Invalid, "Invalid block values"
    end
    def media_ids(blocks)
      Array(blocks).flat_map { |block| [ block["media_id"], *Array(block["media_ids"]) ] }.compact.uniq
    end
    def blank(type)
      raise Invalid unless TYPES.include?(type)
      result = { "type" => type }
      result["items"] = type == "features" ? [ { "heading" => "Your service", "text" => "Describe what you offer." } ] : [ { "question" => "A common question", "answer" => "Write a clear answer." } ] if %w[features faq].include?(type)
      normalize([ result ]).first
    end
  end
end
