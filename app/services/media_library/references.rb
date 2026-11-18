module MediaLibrary
  module References
    module_function
    def ids(snapshot)
      [ snapshot["featured_media_id"], *ContentBlocks::Schema.media_ids(snapshot["blocks"]) ].compact.map(&:to_i).uniq
    end
    def working!(actor:, content:, attributes:)
      blocks = attributes.key?("blocks") ? ContentBlocks::Schema.normalize(attributes["blocks"]) : ContentBlocks::Schema.normalize(content.blocks)
      blocks += pattern_value(attributes["pattern_key"]) if attributes["pattern_key"].present?
      blocks << ContentBlocks::Schema.blank(attributes["add_block"]) if attributes["add_block"].present?
      if attributes["remove_block"].present?
        index = Integer(attributes["remove_block"].to_s, 10)
        raise ContentBlocks::Schema::Invalid unless index.between?(0, blocks.length - 1)
        blocks.delete_at(index)
      end
      if attributes["move_block"].present?
        match = /\A(\d+):(up|down)\z/.match(attributes["move_block"])
        raise ContentBlocks::Schema::Invalid unless match
        index = match[1].to_i
        target = index + (match[2] == "up" ? -1 : 1)
        raise ContentBlocks::Schema::Invalid unless index.between?(0, blocks.length-1) && target.between?(0, blocks.length-1)
        blocks[index], blocks[target] = blocks[target], blocks[index]
      end
      if attributes["add_item"].present?
        index = Integer(attributes["add_item"].to_s, 10)
        block = blocks.fetch(index)
        raise ContentBlocks::Schema::Invalid unless %w[features faq].include?(block["type"])
        fields = block["type"] == "features" ? %w[heading text] : %w[question answer]
        block["items"] << fields.to_h { |field| [ field, "" ] }
      end
      content.blocks = ContentBlocks::Schema.normalize(blocks)
      content.featured_media_id = ContentBlocks::Schema.media_id(attributes["featured_media_id"]) if attributes.key?("featured_media_id")
      wanted = ids(content.attributes)
      previous = content.media_references.where(stage: "draft").lock.pluck(:media_asset_id)
      details = {}
      wanted.sort.each do |id|
        asset = MediaAsset.ready.lock.find(id)
        readable = asset.author_id == actor.id || Identity::Capabilities.allowed?(actor, :manage_media)
        raise Identity::Capabilities::Denied unless readable || (previous.include?(id) && content.media_details.to_h.key?(id.to_s))
        details[id.to_s] = readable ? asset.accessibility_snapshot : content.media_details.fetch(id.to_s)
      end
      content.media_details = details
      sync!(content, "draft", wanted) if content.persisted?
    rescue ArgumentError, IndexError, KeyError, TypeError
      raise ContentBlocks::Schema::Invalid, "Invalid block operation"
    end
    def pattern_value(key)
      ContentBlocks::Patterns.fetch(key)
    end
    def sync!(owner, stage, wanted)
      fields = case stage
      when "draft", "live" then { content_id: owner.id }
      when "revision" then { content_revision_id: owner.id }
      when "preview" then { content_preview_id: owner.id }
      else raise ArgumentError
      end
      MediaReference.where(fields.merge(stage: stage)).delete_all
      wanted.each { |id| MediaReference.create!(fields.merge(stage: stage, media_asset_id: id)) }
    end
  end
end
