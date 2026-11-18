module Portability
  class Export
    class TooLarge < StandardError; end
    SITE_FIELDS = %w[title tagline canonical_origin locale timezone indexing_enabled home_mode homepage_ref].freeze
    def self.call(actor:, include_private: false)
      Site.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        actor.lock!
        Identity::Capabilities.require!(actor, :manage_identity)
        relation = include_private ? Content.all : Content.publicly_visible
        contents = relation.order(:id).limit(501).lock.to_a
        raise TooLarge, "Use at most 500 content records in a manifest" if contents.length > 500
        total_bytes = 0
        scanned_revisions = 0
        media = {}
        terms = {}
        revisions = []
        records = contents.map do |content|
          snapshot = include_private ? content.snapshot : content.published_snapshot.deep_dup
          reference = "#{content.type.downcase}:#{content.id}"
          wanted = MediaLibrary::References.ids(snapshot)
          wanted.each do |id|
            asset = MediaAsset.lock.find(id)
            media[asset.sha256] ||= { "sha256" => asset.sha256, "content_type" => asset.content_type,
              "byte_size" => asset.byte_size, "width" => asset.width, "height" => asset.height,
              "file" => "media/#{asset.sha256}.png", "available" => MediaLibrary::Delivery.exists?(asset) }
          end
          term_refs = Array(snapshot["term_ids"]).map do |id|
            term = Term.lock.find(id)
            taxonomy = Taxonomy.lock.find(term.taxonomy_id)
            ref = "#{taxonomy.kind}:#{term.slug}"
            terms[ref] = { "ref" => ref, "kind" => taxonomy.kind, "name" => term.name, "slug" => term.slug }
            ref
          end
          history = content.content_revisions
          history = history.where(event: %w[publish scheduled_publish]) unless include_private
          history.in_batches(of: 20) do |batch|
            batch.lock.each do |revision|
              scanned_revisions += 1
              raise TooLarge, "Revision selection exceeds manifest limits" if scanned_revisions > 2000 || revisions.length >= 1000
              next if !include_private && revision.snapshot["visibility"] != "public"
              revisions << { "content_ref" => reference, "number" => revision.number, "event" => revision.event, "sha256" => Digest::SHA256.hexdigest(CanonicalJson.dump(revision.snapshot)) }
            end
          end
          details = snapshot.fetch("media_details", {}).to_h.transform_keys { |id| MediaAsset.lock.find(id).public_id }
          body = snapshot.slice("title", "slug", "body", "excerpt", "visibility", "template_key", "meta_title", "meta_description", "home_page")
          body.merge!("ref" => reference, "kind" => content.type, "author" => User.lock.find(content.author_id).username,
            "state" => include_private ? content.status : "published", "published_at" => content.published_at&.iso8601,
            "term_refs" => term_refs, "featured_media_ref" => content.featured_media_id && include_private ? MediaAsset.lock.find(content.featured_media_id).sha256 : snapshot["featured_media_id"] && MediaAsset.lock.find(snapshot["featured_media_id"]).sha256,
            "blocks" => portable_blocks(snapshot["blocks"]), "media_details" => details,
            "featured_media_detail_ref" => snapshot["featured_media_id"] && MediaAsset.lock.find(snapshot["featured_media_id"]).public_id)
          total_bytes += CanonicalJson.dump(body).bytesize
          raise TooLarge, "Content exceeds 4 MiB manifest selection" if total_bytes > 4 * 1024 * 1024
          body
        end
        Activity::Recorder.record!(actor: actor, action: "export.manifest", subject: site, details: { selection: include_private ? "owner_private" : "public" })
        { "format" => "railpress.content", "format_version" => 1, "selection" => include_private ? "owner_private" : "public",
          "exported_at" => Time.current.iso8601, "media_payloads_included" => false,
          "site" => site.attributes.slice(*SITE_FIELDS).merge("homepage_ref" => contents.find { |item| item.id == site.homepage_content_id }&.then { |item| "#{item.type.downcase}:#{item.id}" }), "content" => records, "taxonomy" => terms.values,
          "media" => media.values, "revision_hashes" => revisions, "menus" => [], "redirects" => [],
          "features" => { "editorial" => 1, "media_manifest" => 1, "menus" => 0, "redirects" => 0 }, "extensions" => { "privacy" => { "privacy_first_anonymous" => site.privacy_first_anonymous? } }.merge(site.organization_name.present? ? { "seo" => { "organization_name" => site.organization_name } } : {}) }
      end
    end
    def self.portable_blocks(blocks)
      ContentBlocks::Schema.normalize(blocks).map do |block|
        item = block.deep_dup
        if item["media_id"]
          asset = MediaAsset.lock.find(item.delete("media_id"))
          item["media_ref"] = asset.sha256
          item["media_detail_ref"] = asset.public_id
        end
        item.delete("media_id")
        if item.key?("media_ids")
          assets = item.delete("media_ids").map { |id| MediaAsset.lock.find(id) }
          item["media_refs"] = assets.map(&:sha256)
          item["media_detail_refs"] = assets.map(&:public_id)
        end
        item
      end
    end
  end
end
