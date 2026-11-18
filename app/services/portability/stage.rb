module Portability
  module Stage
    module_function
    def target(batch, kind, ref)
      return nil unless ref
      batch.import_items.find_by!(kind: kind, source_ref: ref, state: %w[staged matched activated]).target_id
    end
    def author(batch, snapshot, content_ref)
      ref = snapshot["author_ref"]
      id = ref ? batch.decisions.fetch("authors").fetch(ref) : batch.decisions.fetch("unassigned").fetch(content_ref)
      Imports.valid_author!(id); id
    end
    def snapshot(batch, source, content_ref)
      result = source.except("author_ref", "term_refs", "featured_media_ref").deep_dup
      result["author_id"] = author(batch, source, content_ref)
      result["visibility"] = "private"
      result["term_ids"] = source["term_refs"].map { |ref| target(batch, "term", ref) }
      result["featured_media_id"] = target(batch, "media", source["featured_media_ref"])
      result["blocks"] = source["blocks"].map do |block|
        out = block.deep_dup
        out["media_id"] = target(batch, "media", out.delete("media_ref")) if out.key?("media_ref")
        out["media_ids"] = out.delete("media_refs").map { |ref| target(batch, "media", ref) } if out.key?("media_refs")
        out
      end
      result["media_details"] = source["media_details"].to_h.to_h do |ref, details|
        id = target(batch, "media", ref)
        [ id.to_s, details.merge("public_id" => MediaAsset.find(id).public_id) ]
      end
      result
    end
    def tree(batch, menu, source)
      source.map do |row|
        key = node_key(batch, menu, row["ref"])
        { "key" => key, "parent_key" => row["parent_ref"] && node_key(batch, menu, row["parent_ref"]), "position" => row["position"], "label" => row["label"], "kind" => row["kind"],
          "content_id" => %w[Page Post].include?(row["kind"]) ? target(batch, "content", row["target_ref"]) : nil,
          "term_id" => row["kind"] == "Term" ? target(batch, "term", row["target_ref"]) : nil, "url" => row["url"] }
      end
    end
    def node_key(batch, menu, ref)
      item = batch.import_items.find_by!(kind: "menu", target_id: menu.id)
      keys = item.details.fetch("node_keys")
      keys.fetch(ref)
    end
    def perform!(batch, item, source, payloads)
      raise Format::Invalid, "journal_source_integrity" unless Imports.source_sha(source) == item.source_sha256 && source["ref"] == item.source_ref
      if item.kind == "media"
        choice = batch.decisions["media"].fetch(source["ref"])
        if choice["action"] == "create"
          MediaLibrary::Upload.call(actor: batch.actor, io: StringIO.new(payloads.fetch("media/#{source['display']['sha256']}.png")), filename: "import.png", content_type: "image/png", attributes: source.fetch("metadata"), import_item: item,
            import_thumbnail: payloads.fetch("media/#{source['thumbnail']['sha256']}.png"))
          return
        end
      end
      Authority.record_locked(batch) do |site, actor, _session|
        Context.require_item!(item)
        record = case item.kind
        when "author"
          user = User.lock.find(batch.decisions.fetch("authors").fetch(source.fetch("ref")))
          Imports.valid_author!(user.id)
          Identities.bind!(site, "author", user.id, source.fetch("ref"))
          item.created_record = false
          user
        when "term"
          choice = batch.decisions["terms"].fetch(source["ref"])
          if choice["action"] == "match"
            term = Term.lock.find(choice.fetch("target_id"))
            raise Imports::Conflict, "Matched taxonomy changed." unless term.name == source["name"] && term.slug == source["slug"] && term.taxonomy.kind == source["kind"]
            item.created_record = false; term
          else
            item.created_record = true
            Editorial::Terms.create!(actor: actor, kind: source.fetch("kind"), name: source.fetch("name"), slug: choice.fetch("slug", source.fetch("slug")))
          end
        when "media"
          asset = MediaAsset.ready.lock.find(batch.decisions["media"].fetch(source["ref"]).fetch("target_id"))
          raise Imports::Conflict, "Matched media changed." unless asset.sha256 == source["display"]["sha256"] && asset.thumbnail_sha256 == source["thumbnail"]["sha256"] && asset.attributes.slice(*MediaAsset::METADATA) == source["metadata"]
          %w[display thumbnail].each do |variant|
            blob = variant == "display" ? asset.blob : asset.thumbnail_blob
            raise Format::Invalid, "matched_media_storage_integrity" unless Digest::SHA256.hexdigest(blob.download) == source[variant]["sha256"]
          end
          item.created_record = false; asset
        when "content"
          choice = batch.decisions["content"].fetch(source["ref"])
          if choice["action"] == "match"
            previous = Imports.previous_match(site, "content", source)
            raise Imports::Conflict, "Prior import changed." unless previous && Fingerprint.current(previous) == previous.target_sha256
            item.created_record = false; Content.lock.find(previous.target_id)
          else
            attributes = snapshot(batch, source.fetch("working"), source.fetch("ref"))
            attributes["slug"] = choice.fetch("slug", attributes.fetch("slug"))
            item.created_record = true
            Editorial::PortableContent.create!(actor: actor, item: item, snapshot: attributes, author_id: attributes.fetch("author_id"))
          end
        when "revision"
          parent = batch.import_items.find_by!(kind: "content", source_ref: source.fetch("content_ref"))
          if !parent.created_record
            previous = Imports.previous_match(site, "revision", source)
            raise Imports::Conflict, "Matched revision is unavailable." unless previous && Fingerprint.current(previous) == previous.target_sha256
            item.created_record = false; ContentRevision.find(previous.target_id)
          else
            content = Content.lock.find(parent.target_id)
            attributes = snapshot(batch, source.fetch("snapshot"), source.fetch("content_ref"))
            # Source visibility is historical, never a live publication authority.
            attributes["visibility"] = source["snapshot"]["visibility"]
            item.created_record = true
            Editorial::PortableContent.revision!(actor: actor, item: item, content: content, snapshot: attributes, history: source.fetch("history"), source_number: source["number"], source_event: source["event"], source_created_at: source["created_at"])
          end
        when "menu"
          item.created_record = true
          menu = Navigation::Mutation.call(actor: actor, operation: "create", expected_state: Navigation::Mutation.generation(site), payload: { "name" => source.fetch("name") })
          keys = (source["draft"] + Array(source["live"])).map { |r| r["ref"] }.uniq.to_h { |ref| [ ref, SecureRandom.hex(16) ] }
          item.update!(target_id: menu.id, details: item.details.merge("node_keys" => keys))
          keys.each { |ref, key| Identities.bind!(site, "menu_node", "#{menu.id}:#{key}", ref) }
          Navigation::Mutation.call(actor: actor, menu: menu, expected_version: menu.lock_version, expected_state: Navigation::Mutation.generation(site), operation: "import_tree", payload: { "tree" => tree(batch, menu, source.fetch("draft")) })
        end
        Identities.bind!(site, item.kind, record.id, source.fetch("ref")) if item.created_record
        details = item.details.merge("source_record" => source)
        details["history"] = source.fetch("history") if item.kind == "content"
        item.update!(target_id: record.id, state: item.created_record ? "staged" : "matched", details: details)
        item.update!(target_sha256: Fingerprint.current(item))
      end
    end
  end
end
