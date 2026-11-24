# frozen_string_literal: true

module Seo
  module SocialImage
    Image = Data.define(:url, :alt, :width, :height)
    module_function

    def call(content:, snapshot:, origin:)
      media_ids = [ snapshot["featured_media_id"], *Array(snapshot["blocks"]).flat_map { |block| [ block["media_id"], *block["media_ids"] ] } ].compact.uniq
      return if media_ids.empty?

      assets = MediaAsset.ready.joins(:media_references)
        .where(id: media_ids, media_references: { content_id: content.id, stage: "live" }).index_by(&:id)
      media_ids.each do |id|
        detail = snapshot.fetch("media_details", {})[id.to_s]
        asset = assets[id.to_i]
        next unless detail && asset && detail["sha256"] == asset.sha256

        alt = detail["alt_text"].to_s.squish
        next if detail["decorative"] || alt.blank? || !MediaLibrary::Delivery.exists?(asset)

        url = CanonicalUrl.new(origin: origin).call("/media/#{content.id}/#{asset.public_id}/display")
        return Image.new(url.freeze, alt.freeze, detail["width"], detail["height"])
      end
      nil
    end
  end
end
