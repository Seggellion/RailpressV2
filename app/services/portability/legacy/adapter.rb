module Portability
  module Legacy
    # Original structural adapter for the pinned legacy evidence. Input is an
    # explicitly prepared extraction document, never a DB connection or SQL dump.
    class Adapter
      COLLECTIONS = %w[pages articles posts categories post_categories media sections blocks rich_texts attachments blobs].freeze
      FIELDS = {
        "pages"=>%w[id user_id title slug content published category_id created_at updated_at meta_title meta_description],
        "articles"=>%w[id user_id title slug content published published_at category_id created_at updated_at bnn owner_authored article_shards meta_title meta_description],
        "posts"=>%w[id user_id title slug content published published_at post_category_id created_at updated_at meta_title meta_description],
        "categories"=>%w[id name slug parent_id], "post_categories"=>%w[id name slug published trashed],
        "media"=>%w[id approved shard_id portable], "sections"=>%w[id name position body template],
        "blocks"=>%w[id section_id position block_type content block_link media_id],
        "rich_texts"=>%w[id record_type record_id name body],
        "attachments"=>%w[id record_type record_id name blob_id],
        "blobs"=>%w[id filename content_type byte_size checksum]
      }.freeze
      def initialize(document:, decisions:, payloads:)
        @input, @decisions, @payloads = document, decisions, payloads
        @conflicts = []; @excluded = []; @changes = []; @authors = {}; @terms = {}; @media = {}; @content = []
      end
      def call
        Format.object!(@input, %w[format source site approved blob_map embedded_map] + COLLECTIONS)
        raise Format::Invalid, "legacy_input_format" unless @input["format"] == "railpress.legacy_extract.v1"
        Format.ref!(@input["source"])
        Format.object!(@input["approved"], %w[media sections])
        %w[media sections].each { |k| Format.list!(@input["approved"][k], 64) }
        %w[blob_map embedded_map].each { |key| raise Format::Invalid, "legacy_map" unless @input[key].is_a?(Hash) && @input[key].length <= 256 }
        COLLECTIONS.each do |collection|
          records = Format.list!(@input[collection], 2000)
          seen = []
          records.each do |record|
            Format.object!(record, FIELDS.fetch(collection), required: [ "id" ])
            key = legacy_id(record["id"]); raise Format::Invalid, "duplicate_legacy_identity" if seen.include?(key)
            seen << key
          end
        end
        @input["media"].each do |record|
          if record["approved"] != true || record["shard_id"] || !@input["approved"]["media"].map(&:to_s).include?(record["id"].to_s)
            @excluded << { "kind"=>"media", "id"=>record["id"].to_s, "reason"=>"unapproved_or_shard" }; next
          end
          portable = record["portable"]
          unless portable.is_a?(Hash) && portable.dig("rights", "status") == "cleared"
            conflict("Medium", record["id"], "rights", "Provide verified cleared portable media and actual canonical variants; uncertain or revoked rights cannot be waived."); next
          end
          @media[record["id"].to_s] = portable.merge("ref"=>ref("Medium", record["id"]))
        end
        %w[categories post_categories].each do |collection|
          @input[collection].each do |record|
            kind = collection == "categories" ? "Category" : "PostCategory"
            if record["trashed"] == true
              @excluded << { "kind"=>kind, "id"=>record["id"].to_s, "reason"=>"trashed" }; next
            end
            if record["parent_id"]
              unless decision(kind, record["id"], "hierarchy") == "flatten_with_loss"
                conflict(kind, record["id"], "hierarchy", "Pinned Category schema has no parent column. Supply a qualified hierarchy adapter or explicitly accept flattening this hypothetical shape.")
              end
              @changes << { "ref"=>ref(kind, record["id"]), "loss"=>"unsupported_hierarchy_flattened" }
            end
            slug = Railpress::ContentRoutes.slug(record["slug"].presence || record["name"])
            @terms[[ kind, record["id"].to_s ]] = { "ref"=>ref(kind, record["id"]), "kind"=>"category", "name"=>record["name"].to_s, "slug"=>slug }
          end
        end
        %w[pages articles posts].each do |collection|
          @input[collection].each do |record|
            source_kind = { "pages"=>"Page", "articles"=>"Article", "posts"=>"Post" }.fetch(collection)
            if collection == "articles" && (record["bnn"] == true || record["owner_authored"] == true || Array(record["article_shards"]).any?)
              @excluded << { "kind"=>source_kind, "id"=>record["id"].to_s, "reason"=>"game_bnn_owner_authored_or_shard" }; next
            end
            if collection == "articles" && !(record["bnn"] == false && record["owner_authored"] == false && record["article_shards"].is_a?(Array))
              conflict(source_kind, record["id"], "unknown_game_flags", "Provide explicit false BNN/owner-authored flags and an empty shard list. Unknown game provenance is not ordinary content.")
              next
            end
            convert_content(source_kind, record)
          end
        end
        @input["sections"].each do |section|
          next if @input["approved"]["sections"].map(&:to_s).include?(section["id"].to_s)
          @excluded << { "kind"=>"Section", "id"=>section["id"].to_s, "reason"=>"not_explicitly_approved" }
        end
        manifest = { "format"=>"railpress.site", "version"=>2, "source"=>@input["source"], "selection"=>"owner_private", "site"=>@input["site"], "authors"=>@authors.values,
          "content"=>@content, "revisions"=>[], "terms"=>@terms.values, "media"=>@media.values, "menus"=>[], "redirects"=>[], "appearance"=>nil }
        selected_payloads = @media.values.flat_map { |r| %w[display thumbnail].map { |v| "media/#{r.fetch(v).fetch('sha256')}.png" } }.uniq.to_h { |path| [ path, @payloads[path] ] }
        if @conflicts.empty?
          Format.check!(manifest, selected_payloads)
          { "manifest"=>manifest, "payloads"=>selected_payloads, "report"=>report, "archive"=>Railpress::SiteArchive.build(manifest, selected_payloads) }
        else
          { "manifest"=>nil, "payloads"=>{}, "report"=>report, "archive"=>nil }
        end
      rescue KeyError, TypeError => error
        raise Format::Invalid, "incomplete_legacy_extraction: #{error.class.name}"
      end
      def legacy_id(value)
        raise Format::Invalid, "legacy_identity" unless value.is_a?(Integer) && value.positive? || value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,18}\z/)
        value.to_s
      end
      def ref(kind, id)
        hex = Digest::SHA256.hexdigest(@input.fetch("source") + ":" + kind + ":" + legacy_id(id))[0, 32]
        hex[12] = "5"; hex[16] = "8"
        [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
      end
      def decision(kind, id, key) = @decisions.fetch("records", {}).fetch("#{kind}:#{id}", {})[key]
      def conflict(kind, id, code, resolution)
        @conflicts << { "source"=>"#{kind}:#{id}", "code"=>code, "resolution"=>resolution }
      end
      def report
        { "conflicts"=>@conflicts, "excluded"=>@excluded, "explicit_changes"=>@changes, "content_count"=>@content.length,
          "history"=>"No source revision chain is invented. Missing source history remains unknown.", "source_access"=>"Prepared synthetic extraction only; no database, URL, blob-key, SGID or filesystem resolution." }
      end
      def date(kind, record, field)
        value = record[field]
        if value.nil?
          unless decision(kind, record["id"], "missing_dates") == "preserve_unknown"
            conflict(kind, record["id"], "missing_#{field}", "Explicitly retain unknown history; never substitute an import date.")
          end
          return nil
        end
        Format.timestamp!(value); value
      rescue Format::Invalid
        conflict(kind, record["id"], "ambiguous_#{field}", "Supply an approved UTC timestamp with its original precision and provenance; ambiguous dates cannot be guessed.")
        nil
      end
      def convert_content(kind, record)
        target_kind = kind == "Page" ? "Page" : "Post"
        external_ref = ref(kind, record["id"])
        label = @decisions.fetch("authors", {})[record["user_id"].to_s]
        author = nil
        if label && label != "UNASSIGNED"
          Format.string!(label, 120, empty: false)
          author = ref("Author", record["user_id"]); @authors[author] = { "ref"=>author, "label"=>label }
        elsif decision(kind, record["id"], "missing_author") != "preserve_unassigned"
          conflict(kind, record["id"], "missing_author", "Map an approved opaque author label or explicitly preserve UNASSIGNED; no source accounts are accepted.")
        end
        raw = record["content"].to_s
        rich = @input["rich_texts"].select { |r| r["record_type"] == kind && r["record_id"].to_s == record["id"].to_s && r["name"] == "content" }
        conflict(kind, record["id"], "duplicate_rich_text", "Resolve the polymorphic source association.") if rich.length > 1
        raw = rich.first["body"].to_s if rich.first
        raise Format::Invalid, "invalid_utf8" unless raw.valid_encoding?
        Format.string!(raw, 200_000)
        fragment = Nokogiri::HTML5.fragment(raw)
        embedded = []
        fragment.css("action-text-attachment").each do |attachment|
          blob = @input["embedded_map"][attachment["sgid"].to_s]
          medium_id = blob && @input["blob_map"][blob.to_s]
          medium = medium_id && @media[medium_id.to_s]
          if medium
            embedded << { "type"=>"image", "media_ref"=>medium["ref"], "caption"=>medium["metadata"]["caption"] }
          else
            conflict(kind, record["id"], "missing_action_text_media", "Provide an explicitly approved SGID-to-blob-to-media map and actual cleared bytes; SGIDs will never be resolved.")
          end
          attachment.remove
        end
        clean = Editorial::RichText.clean(fragment.to_html)
        if clean != raw && decision(kind, record["id"], "html") != "sanitize"
          conflict(kind, record["id"], "html_sanitization", "Review malformed/active HTML and explicitly approve the core sanitizer result.")
        end
        @changes << { "ref"=>external_ref, "change"=>"core_html_sanitized" } if clean != raw
        terms = []
        category_id = kind == "Post" ? record["post_category_id"] : record["category_id"]
        if category_id
          term = @terms[[ kind == "Post" ? "PostCategory" : "Category", category_id.to_s ]]
          term ? terms << term["ref"] : conflict(kind, record["id"], "missing_category", "Supply the approved matching category; do not merge by name.")
        end
        attachments = @input["attachments"].select do |r|
          (r["record_type"] == kind && r["record_id"].to_s == record["id"].to_s) || (r["record_type"] == "ActionText::RichText" && rich.any? { |rt| rt["id"].to_s == r["record_id"].to_s })
        end
        attachments.each do |attachment|
          blob = @input["blobs"].find { |b| b["id"].to_s == attachment["blob_id"].to_s }
          medium_id = @input["blob_map"][attachment["blob_id"].to_s]; medium = medium_id && @media[medium_id.to_s]
          unless blob && medium
            conflict(kind, record["id"], "missing_blob_association", "Reconcile approved polymorphic attachment/blob identity and cleared media bytes."); next
          end
          unless embedded.any? { |b| b["media_ref"] == medium["ref"] }
            embedded << { "type"=>"image", "media_ref"=>medium["ref"], "caption"=>medium["metadata"]["caption"] }
          end
        end
        if embedded.any?
          if decision(kind, record["id"], "embedded_placement") != "append_blocks_with_loss"
            conflict(kind, record["id"], "embedded_placement", "This bounded adapter extracts embedded images and attachment associations into ordered trailing blocks. Explicitly accept that exact placement difference, or supply a reviewed native extraction preserving placement.")
          end
          @changes << { "ref"=>external_ref, "loss"=>"embedded_media_appended_as_blocks" }
        end
        slug = @decisions.fetch("records", {}).fetch("#{kind}:#{record['id']}", {})["slug"] || record["slug"]
        if slug.blank?
          conflict(kind, record["id"], "missing_slug", "Choose a canonical destination slug explicitly; legacy Post has no native slug field.")
          slug = "pending-#{kind.downcase}-#{record['id']}"
        elsif Railpress::ContentRoutes.content_slug(target_kind, slug) != slug
          conflict(kind, record["id"], "legacy_slug", "Choose an explicit canonical slug and review historical redirect requirements.")
        end
        blocks = embedded + section_blocks(kind, record)
        details = blocks.filter_map { |b| b["media_ref"] }.uniq.to_h do |media_ref|
          medium = @media.values.find { |m| m["ref"] == media_ref }
          [ media_ref, medium["metadata"].merge("public_id"=>media_ref, "width"=>medium["width"], "height"=>medium["height"], "sha256"=>medium["display"]["sha256"]) ]
        end
        snapshot = { "type"=>target_kind, "title"=>record["title"].to_s, "slug"=>slug, "body"=>clean, "excerpt"=>"", "visibility"=>"public", "template_key"=>"standard", "meta_title"=>record["meta_title"].to_s, "meta_description"=>record["meta_description"].to_s, "home_page"=>false,
          "author_ref"=>author, "term_refs"=>terms, "featured_media_ref"=>nil, "blocks"=>blocks, "media_details"=>details,
          "portable_metadata"=>{ "source"=>{ "kind"=>kind, "identity"=>record["id"].to_s }, "authorship"=>author ? "APPROVED LABEL; destination mapping required" : "UNASSIGNED", "review"=>{ "status"=>"AWAITING DESTINATION EDITORIAL REVIEW" } } }
        history = { "state"=>record["published"] == true ? "published" : "draft", "created_at"=>date(kind, record, "created_at"), "updated_at"=>date(kind, record, "updated_at"), "published_at"=>record["published"] == true ? date(kind, record, "published_at") : nil, "first_published_at"=>record["published"] == true ? record["published_at"] : nil, "scheduled_at"=>nil }
        @content << { "ref"=>external_ref, "working"=>snapshot, "live"=>record["published"] == true ? snapshot.deep_dup : nil, "history"=>history }
      end
      def section_blocks(kind, record)
        ids = decision(kind, record["id"], "sections") || []
        Format.list!(ids, 40)
        ids.flat_map do |id|
          section = @input["sections"].find { |r| r["id"].to_s == id.to_s }
          unless section && @input["approved"]["sections"].map(&:to_s).include?(id.to_s)
            conflict(kind, record["id"], "section_not_approved", "Select an explicitly approved Section; templates are never executed."); next []
          end
          section_body = section["body"].to_s
          if Editorial::RichText.clean(section_body) != section_body && decision(kind, record["id"], "html") != "sanitize"
            conflict(kind, record["id"], "section_html", "Review and explicitly approve core sanitization for the section body.")
          end
          prefix = section_body.empty? ? [] : [ { "type"=>"paragraph", "html"=>Editorial::RichText.clean(section_body) } ]
          prefix + @input["blocks"].select { |b| b["section_id"].to_s == id.to_s }.sort_by { |b| [ b["position"].to_i, b["id"].to_i ] }.flat_map do |block|
            mapping = decision(kind, record["id"], "native_blocks")
            if mapping.is_a?(Hash) && mapping.key?(block["id"].to_s)
              converted = Format.list!(mapping.fetch(block["id"].to_s), 40)
              raise Format::Invalid, "empty_native_block_mapping" if converted.empty?
              @changes << { "ref"=>ref(kind, record["id"]), "change"=>"explicit_native_block_mapping", "block"=>block["id"].to_s }
              next converted.deep_dup
            end
            if block["block_link"].present?
              Navigation::SafeUrl.validate!(block["block_link"])
              unless decision(kind, record["id"], "block_links") == "omit_with_loss"
                conflict(kind, record["id"], "block_link_semantics", "Native image/text blocks do not carry this legacy link. Supply an approved native mapping or explicitly accept omitting that link.")
              end
              @changes << { "ref"=>ref(kind, record["id"]), "loss"=>"legacy_block_link_omitted", "block"=>block["id"].to_s }
            end
            converted = case block["block_type"]
            when 0, "image"
              medium = @media[block["media_id"].to_s]
              if medium then { "type"=>"image", "media_ref"=>medium["ref"], "caption"=>block["content"].to_s }
              else conflict(kind, record["id"], "block_media", "Provide approved media for image block #{block['id']}."); nil
              end
            when 1, "rich_text"
              raw = block["content"].to_s
              clean = Editorial::RichText.clean(raw)
              if clean != raw && decision(kind, record["id"], "html") != "sanitize"
                conflict(kind, record["id"], "block_html", "Review and explicitly approve the core sanitizer result for block #{block['id']}.")
              end
              @changes << { "ref"=>ref(kind, record["id"]), "change"=>"block_html_sanitized", "block"=>block["id"].to_s } if clean != raw
              { "type"=>"paragraph", "html"=>clean }
            when 2, "single_line_text" then { "type"=>"heading", "level"=>2, "text"=>block["content"].to_s }
            else conflict(kind, record["id"], "unsupported_block", "Map JSON/unknown block #{block['id']} into reviewed native semantic blocks; executable templates are not imported."); nil
            end
            converted ? [ converted ] : []
          end
        end
      end
    end
  end
end
