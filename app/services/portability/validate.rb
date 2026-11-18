module Portability
  module Validate
    class Invalid < StandardError; end
    ROOT_KEYS = %w[format format_version selection exported_at media_payloads_included site content taxonomy media revision_hashes menus redirects features extensions].freeze
    module_function
    def call(json)
      raise Invalid, "Manifest exceeds 5 MiB" unless json.is_a?(String) && json.bytesize <= 5 * 1024 * 1024
      object = JSON.parse(json, max_nesting: 30)
      raise Invalid, "Unsupported manifest" unless object.is_a?(Hash) && object.keys.sort == ROOT_KEYS.sort &&
        object["format"] == "railpress.content" && object["format_version"] == 1 && object["media_payloads_included"] == false &&
        %w[public owner_private].include?(object["selection"])
      secret_keys!(object)
      raise Invalid, "Unimplemented feature payload" unless object["menus"] == [] && object["redirects"] == [] &&
        object["features"] == { "editorial" => 1, "media_manifest" => 1, "menus" => 0, "redirects" => 0 }
      raise Invalid, "Invalid site settings" unless object["site"].is_a?(Hash) && object["site"].keys.sort == Export::SITE_FIELDS.sort
      origin = URI.parse(object["site"].fetch("canonical_origin"))
      raise Invalid, "Unsafe canonical origin" unless origin.is_a?(URI::HTTPS) && origin.host && !origin.userinfo && [ "", "/" ].include?(origin.path) && !origin.query && !origin.fragment
      TZInfo::Timezone.get(object["site"].fetch("timezone"))
      raise Invalid, "Unsupported site preferences" unless object["site"]["locale"]=="en" && %w[static blog].include?(object["site"]["home_mode"]) && [ true, false ].include?(object["site"]["indexing_enabled"])
      checksums = object.fetch("media").map do |item|
        raise Invalid, "Unknown media fields" unless item.keys.sort == %w[sha256 content_type byte_size width height file available].sort
        sha = item.fetch("sha256")
        raise Invalid, "Unsafe media manifest" unless digest?(sha) && item["content_type"] == "image/png" &&
          item["file"] == "media/#{sha}.png" && item["byte_size"].is_a?(Integer) && item["byte_size"].between?(1, MediaLibrary::Processor::OUTPUT_BYTES) &&
          item["width"].is_a?(Integer) && item["height"].is_a?(Integer) && item["width"].between?(1, 1600) && item["height"].between?(1, 1600)
        sha
      end
      raise Invalid, "Duplicate media checksum" unless checksums.uniq == checksums
      references = object.fetch("content").map do |item|
        raise Invalid, "Invalid content" unless %w[Page Post].include?(item["kind"]) && item["ref"].match?(/\A(?:page|post):\d+\z/) &&
          item["slug"].present? && item["slug"] == Railpress::ContentRoutes.content_slug(item["kind"], item["slug"]) && !Railpress::ContentRoutes.reserved_content_slug?(item["kind"], item["slug"])
        raise Invalid, "Unsafe body" unless item["body"].is_a?(String) && item["body"] == Editorial::RichText.clean(item["body"])
        raise Invalid, "Private selection mismatch" if object["selection"] == "public" && (item["state"] != "published" || item["visibility"] != "public")
        allowed = %w[title slug body excerpt visibility template_key meta_title meta_description home_page ref kind author state published_at term_refs featured_media_ref featured_media_detail_ref blocks media_details]
        raise Invalid, "Unknown content fields" unless (item.keys-allowed).empty?
        ids = [ item["featured_media_ref"], *item.fetch("blocks").flat_map { |block| [ block["media_ref"], *Array(block["media_refs"]) ] } ].compact
        raise Invalid, "Unknown media reference" unless (ids - checksums).empty?
        raise Invalid, "Too many blocks" if item.fetch("blocks").length > 40
        item.fetch("blocks").each do |block|
          fields = case block["type"]
          when "heading" then %w[type text level]
          when "paragraph" then %w[type html]
          when "image" then %w[type media_ref media_detail_ref caption]
          when "gallery" then %w[type media_refs media_detail_refs caption]
          when "hero" then %w[type heading text label url media_ref media_detail_ref]
          when "call_to_action" then %w[type heading text label url]
          when "external_media" then %w[type heading url]
          when "features", "faq" then %w[type items]
          when "testimonial" then %w[type quote attribution]
          when "contact" then %w[type heading address email phone]
          else []
          end
          raise Invalid, "Unknown block fields" unless (block.keys-fields).empty?
          raise Invalid, "Unsupported block" unless ContentBlocks::Schema::TYPES.include?(block["type"])
          ContentBlocks::Schema.url(block["url"]) if block.key?("url")
          raise Invalid, "Unsafe rich block" if block["html"] && block["html"] != Editorial::RichText.clean(block["html"])
        end
        item["ref"]
      end
      raise Invalid, "Duplicate content reference" unless references.uniq == references
      taxonomy = object.fetch("taxonomy").map do |term|
        raise Invalid, "Invalid term" unless term.keys.sort == %w[ref kind name slug].sort && %w[category tag].include?(term["kind"]) &&
          term["slug"].present? && term["slug"] == Railpress::ContentRoutes.slug(term["slug"]) && term["ref"]=="#{term['kind']}:#{term['slug']}"
        term["ref"]
      end
      raise Invalid, "Duplicate term" unless taxonomy.uniq == taxonomy
      object["content"].each do |item|
        raise Invalid, "Unknown term" unless (item.fetch("term_refs")-taxonomy).empty?
        details = item.fetch("media_details")
        raise Invalid, "Unsafe media details" unless details.all? { |ref, detail| ref == detail["public_id"] && checksums.include?(detail["sha256"]) }
        usages = [ [ item["featured_media_ref"], item["featured_media_detail_ref"] ] ]
        item["blocks"].each do |block|
          usages << [ block["media_ref"], block["media_detail_ref"] ] if block["media_ref"]
          if block["media_refs"]
            raise Invalid, "Gallery details mismatch" unless block["media_refs"].length == Array(block["media_detail_refs"]).length
            usages.concat(block["media_refs"].zip(block["media_detail_refs"]))
          end
        end
        usages.each { |sha, ref| raise Invalid, "Unknown media detail" if sha && (!details[ref] || details[ref]["sha256"] != sha) }
      end
      home = object["site"]["homepage_ref"]
      raise Invalid, "Unknown homepage" unless home.nil? || references.include?(home)
      object.fetch("revision_hashes").each do |revision|
        raise Invalid, "Invalid revision hash" unless references.include?(revision["content_ref"]) && digest?(revision["sha256"])
      end
      object
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError, URI::InvalidURIError, TZInfo::InvalidTimezoneIdentifier, ContentBlocks::Schema::Invalid
      raise Invalid, "Malformed or unsafe manifest"
    end
    def digest?(value)
      value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end
    def secret_keys!(value)
      case value
      when Hash
        value.each do |key, item|
          raise Invalid, "Forbidden credential field" if key.match?(/password|token|secret|credential|cookie|session|auth_version|storage_key|private_key|smtp|database/i)
          secret_keys!(item)
        end
      when Array then value.each { |item| secret_keys!(item) }
      end
    end
  end
end
