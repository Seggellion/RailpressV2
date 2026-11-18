module Portability
  class Snapshot
    def initialize(site, scope)
      @site, @scope = site, scope
      @terms = {}; @media = {}; @authors = {}; @payloads = {}; @omissions = []
    end
    attr_reader :payloads, :omissions
    def ref(kind, key) = Identities.reference(@site, kind, key)
    def capture
      private_scope = @scope.fetch("mode") == "owner_private"
      relation = private_scope ? Content.where(id: @scope.fetch("content_ids")) : Content.publicly_visible
      contents = relation.order(:id).limit(501).lock.to_a
      raise Format::Invalid, "content_limit" if contents.length > 500
      raise Format::Invalid, "selected_content_missing" if private_scope && contents.map(&:id).sort != @scope["content_ids"].sort
      @content_refs = contents.to_h { |c| [ c.id, ref("content", c.id) ] }
      records = contents.map do |c|
        imported = ImportItem.where(kind: "content", target_id: c.id, state: %w[staged activated matched]).order(:id).last
        historical = (private_scope && imported&.details&.dig("history")) || history(c)
        live = c.publicly_visible? ? snapshot(c.published_snapshot) : nil
        if private_scope && !live && imported&.details&.dig("source_record", "live")
          source_record = imported.details.fetch("source_record")
          native = Stage.snapshot(imported.import_batch, source_record.fetch("live"), imported.source_ref)
          native["visibility"] = source_record["live"].fetch("visibility")
          live = snapshot(native)
        end
        { "ref" => @content_refs.fetch(c.id), "working" => snapshot(private_scope ? c.snapshot : c.published_snapshot),
          "live" => live, "history" => historical }
      end
      revisions = []
      if private_scope && @scope["history"]
        contents.each do |c|
          imported_content = ImportItem.where(kind: "content", target_id: c.id, created_record: true, state: %w[staged activated]).order(:id).first
          original_revisions = ImportItem.where(kind: "revision", target_id: c.content_revisions.select(:id)).to_h { |i| [ i.target_id, i.details["source_record"] ] }
          next_number = original_revisions.values.compact.map { |r| r["number"] }.max || 0
          c.content_revisions.order(:number).lock.each do |revision|
            next if imported_content && revision.event == "create" && revision.number == 1
            raise Format::Invalid, "revision_limit" if revisions.length >= 2000
            original = original_revisions[revision.id]
            portable_number = original ? original.fetch("number") : imported_content ? (next_number += 1) : revision.number
            revisions << { "ref" => ref("revision", revision.id), "content_ref" => @content_refs.fetch(c.id), "number" => portable_number,
              "event" => original&.fetch("event") || revision.event, "created_at" => original&.fetch("created_at") || revision.created_at.utc.iso8601(6),
              "snapshot" => snapshot(revision.snapshot), "history" => original&.fetch("history") || history(c, revision.snapshot, revision.created_at) }
          end
        end
      end
      menus = @scope["menus"] ? menus(private_scope) : []
      appearance = @scope["appearance"] ? appearance() : nil
      site_fields = @site.attributes.slice("title", "tagline", "canonical_origin", "locale", "timezone", "indexing_enabled", "home_mode", "organization_name", "privacy_first_anonymous")
      site_fields["organization_name"] ||= ""
      site_fields["homepage_ref"] = @content_refs[@site.homepage_content_id]
      redirects = Redirect.order(:id).lock.filter_map do |r|
        next unless @content_refs[r.target_content_id]
        { "path" => r.source_path, "content_ref" => @content_refs.fetch(r.target_content_id) }
      end
      data = { "format" => "railpress.site", "version" => 3, "source" => PortabilityState.find_or_create_by!(site: @site).public_id,
        "selection" => @scope.fetch("mode"), "site" => site_fields, "authors" => @authors.values, "content" => records,
        "revisions" => revisions, "terms" => @terms.values, "media" => @media.values, "menus" => menus, "redirects" => redirects, "appearance" => appearance }
      Format.check!(data, @payloads)
    end
    def history(content, snap = nil, at = nil)
      { "state" => snap ? snap.fetch("status", "draft") : content.status,
        "created_at" => content.created_at&.utc&.iso8601(6), "updated_at" => (at || content.updated_at)&.utc&.iso8601(6),
        "published_at" => snap ? snap["published_at"] : content.published_at&.utc&.iso8601(6),
        "first_published_at" => content.first_published_at&.utc&.iso8601(6), "scheduled_at" => snap ? snap["scheduled_at"] : content.scheduled_at&.utc&.iso8601(6) }
    end
    def author(id)
      label = @scope.fetch("author_labels", {})[id.to_s]
      return nil unless label
      key = ref("author", id); @authors[key] ||= { "ref" => key, "label" => label }; key
    end
    def term(id)
      record = Term.lock.find(id); key = ref("term", id)
      @terms[key] ||= { "ref" => key, "kind" => record.taxonomy.kind, "name" => record.name, "slug" => record.slug }; key
    end
    def media(id)
      return nil unless id
      asset = MediaAsset.ready.lock.find(id); key = ref("media", id)
      return key if @media[key]
      raise Format::Invalid, "media_limit" if @media.length >= 64
      rights = @scope.fetch("media_rights", {})[id.to_s]
      raise Format::Invalid, "explicit_media_rights_required" unless rights
      variants = { "display" => asset.blob, "thumbnail" => asset.thumbnail_blob }.to_h do |name, blob|
        bytes = blob.download.b
        expected = name == "display" ? asset.sha256 : asset.thumbnail_sha256
        raise Format::Invalid, "source_media_integrity" unless Digest::SHA256.hexdigest(bytes) == expected
        @payloads["media/#{expected}.png"] = bytes
        [ name, { "sha256" => expected, "bytes" => bytes.bytesize } ]
      end
      @media[key] = { "ref" => key, "metadata" => media_text(asset.attributes.slice(*MediaAsset::METADATA), key, "global"), "rights" => rights,
        "width" => asset.width, "height" => asset.height }.merge(variants)
      key
    end
    # v2 represents absent optional text as an empty string. Ordinary uploads
    # can retain SQL NULL; preserve nonempty text, types and source records.
    def media_text(values, ref, usage)
      fields = %w[caption attribution license_notes]
      fields << "alt_text" if values["decorative"] == true
      absent = fields.select { |field| values.key?(field) && values[field].nil? }
      @omissions << { "media" => ref, "usage" => usage, "absent_text_as_empty" => absent } if absent.any?
      values.merge(absent.to_h { |field| [ field, "" ] })
    end
    def snapshot(source)
      out = source.slice(*Format::SNAPSHOT).except("author_ref", "term_refs", "featured_media_ref", "media_details")
      %w[body excerpt meta_title meta_description].each { |key| out[key] ||= "" }
      out["portable_metadata"] = @scope["mode"] == "owner_private" ? (out["portable_metadata"] || {}) : {}
      out["author_ref"] = author(source["author_id"])
      out["term_refs"] = Array(source["term_ids"]).map { |id| term(id) }
      out["featured_media_ref"] = media(source["featured_media_id"])
      out["blocks"] = ContentBlocks::Schema.normalize(source["blocks"]).map do |block|
        value = block.deep_dup
        value["media_ref"] = media(value.delete("media_id")) if value.key?("media_id")
        value["media_refs"] = value.delete("media_ids").map { |id| media(id) } if value.key?("media_ids")
        value
      end
      out["media_details"] = (source["media_details"] || {}).to_h.to_h do |id, detail|
        key = media(Integer(id.to_s, 10)); [ key, media_text(detail, key, "captured_use").merge("public_id" => key) ]
      end
      out
    end
    def menus(private_scope)
      Menu.where(site: @site, status: "active").order(:id).lock.filter_map do |menu|
        live = menu.published_revision&.snapshot&.fetch("tree", nil)
        next if !private_scope && !live
        serialize = lambda do |tree|
          return nil unless tree
          kept = tree.select { |r| !%w[Page Post].include?(r["kind"]) || @content_refs.key?(r["content_id"]) }
          raise Format::Invalid, "menu_target_outside_private_selection" if private_scope && kept.length != tree.length
          omitted = tree.length - kept.length; @omissions << { "menu" => menu.name, "unexported_targets" => omitted } if omitted.positive?
          keys = kept.map { |r| r["key"] }
          portable = kept.map do |r|
            parent = r["parent_key"]; parent = tree.find { |n| n["key"] == parent }["parent_key"] while parent && !keys.include?(parent)
            { "ref" => ref("menu_node", "#{menu.id}:#{r['key']}"), "parent_ref" => parent && ref("menu_node", "#{menu.id}:#{parent}"),
              "position" => r["position"], "label" => r["label"], "kind" => r["kind"],
              "target_ref" => r["content_id"] ? @content_refs.fetch(r["content_id"]) : r["term_id"] ? term(r["term_id"]) : nil, "url" => r["url"] }
          end
          portable.group_by { |r| r["parent_ref"] }.each_value { |siblings| siblings.sort_by { |r| r["position"] }.each_with_index { |r, i| r["position"] = i } }
          portable
        end
        live_tree = serialize.call(live)
        locations = MenuLocation.where(site: @site).where("draft_menu_id = ? OR published_menu_id = ?", menu.id, menu.id).order(:theme_key, :key).lock.filter_map do |l|
          next if !private_scope && l.published_menu_id != menu.id
          { "theme" => l.theme_key, "key" => l.key, "draft" => private_scope ? l.draft_menu_id == menu.id : true, "live" => l.published_menu_id == menu.id }
        end
        { "ref" => ref("menu", menu.id), "name" => menu.name, "draft" => private_scope ? serialize.call(menu.tree) : live_tree, "live" => live_tree, "locations" => locations }
      end
    end
    def appearance
      state = ThemeState.find_by(site: @site); overlay = state&.active_overlay; package = state&.active_installation
      return nil unless overlay && package
      { "theme" => package.theme_key, "version" => package.version, "digest" => package.digest, "api" => 1,
        "options" => overlay.options, "media" => overlay.media_details.to_h.transform_values { |detail| media(detail.fetch("asset_id")) } }
    end
  end
end
