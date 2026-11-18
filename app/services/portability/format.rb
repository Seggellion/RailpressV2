require Rails.root.join("lib/railpress/site_archive")
module Portability
  module Format
    Invalid = Railpress::SiteArchive::Invalid
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    SHA = /\A[0-9a-f]{64}\z/
    SNAPSHOT = %w[type title slug body excerpt visibility template_key meta_title meta_description home_page author_ref term_refs featured_media_ref blocks media_details portable_metadata].freeze
    METADATA = %w[source history review authorship license internal_links].freeze
    module_function
    def invalid!(message) = raise(Invalid, message)
    def object!(value, fields, required: fields)
      invalid!("unknown_or_missing_fields") unless value.is_a?(Hash) && (value.keys - fields).empty? && (required - value.keys).empty?
    end
    def string!(value, max, empty: true)
      invalid!("invalid_text") unless value.is_a?(String) && value.valid_encoding? && value.length <= max && (empty || !value.empty?) && !value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
    end
    def ref!(value)
      invalid!("invalid_external_identity") unless value.is_a?(String) && UUID.match?(value)
    end
    def list!(value, max)
      invalid!("record_limit") unless value.is_a?(Array) && value.length <= max
      value
    end
    def timestamp!(value)
      return if value.nil?
      invalid!("ambiguous_timestamp") unless value.is_a?(String) && value.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z\z/)
      Date.iso8601(value[0, 10])
      Time.iso8601(value)
    rescue ArgumentError
      invalid!("invalid_timestamp")
    end
    def metadata!(value)
      object!(value, METADATA, required: [])
      invalid!("metadata_size") if JSON.generate(value).bytesize > 32_768
      walk = lambda do |node, depth|
        invalid!("metadata_depth") if depth > 8
        case node
        when Hash
          node.each { |k, v| string!(k, 80); invalid!("protected_metadata") if k.match?(/password|secret|token|credential|session|signing|database|auth_version|operator|trust_key/i); walk.call(v, depth + 1) }
        when Array then list!(node, 100).each { |v| walk.call(v, depth + 1) }
        when String then string!(node, 10_000)
        when Integer, TrueClass, FalseClass, NilClass then nil
        else invalid!("invalid_metadata")
        end
      end
      walk.call(value, 0)
    end
    def check!(manifest, payloads)
      object!(manifest, %w[format version source selection site authors content revisions terms media menus redirects appearance])
      invalid!("unsupported_format") unless manifest["format"] == "railpress.site" && [ 2, 3 ].include?(manifest["version"])
      ref!(manifest["source"])
      invalid!("invalid_selection") unless %w[public owner_private].include?(manifest["selection"])
      registry = {}
      { "authors" => 500, "content" => 500, "revisions" => 2000, "terms" => 1000, "media" => 64, "menus" => 20 }.each do |kind, max|
        list!(manifest[kind], max).each do |record|
          invalid!("invalid_record") unless record.is_a?(Hash)
          ref!(record["ref"])
          invalid!("duplicate_external_identity") if registry.key?(record["ref"])
          registry[record["ref"]] = kind
        end
      end
      reference = lambda do |ref, kind, optional = false, content_type = nil|
        next if optional && ref.nil?
        invalid!("forged_reference") unless registry[ref] == kind
        invalid!("forged_content_kind") if content_type && manifest["content"].find { |r| r["ref"] == ref }.dig("working", "type") != content_type
      end
      site = manifest["site"]
      site_fields = %w[title tagline canonical_origin locale timezone indexing_enabled home_mode homepage_ref organization_name]
      site_fields += [ "privacy_first_anonymous" ] if manifest["version"] == 3
      object!(site, site_fields)
      invalid!("invalid_privacy_policy") if manifest["version"] == 3 && ![ true, false ].include?(site["privacy_first_anonymous"])
      string!(site["title"], 120, empty: false); string!(site["tagline"], 240); string!(site["organization_name"], 200)
      Seo::SiteOrigin.new(site["canonical_origin"])
      invalid!("invalid_site_settings") unless site["locale"] == "en" && %w[static blog].include?(site["home_mode"]) && [ true, false ].include?(site["indexing_enabled"])
      TZInfo::Timezone.get(site["timezone"]); reference.call(site["homepage_ref"], "content", true)
      manifest["authors"].each { |r| object!(r, %w[ref label]); string!(r["label"], 120, empty: false) }
      term_keys = []
      manifest["terms"].each do |r|
        object!(r, %w[ref kind name slug]); string!(r["name"], 100, empty: false)
        invalid!("invalid_term") unless %w[category tag].include?(r["kind"]) && r["slug"].is_a?(String) && r["slug"].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) && r["slug"].length <= 160
        term_keys << [ r["kind"], r["slug"] ]
      end
      invalid!("duplicate_term_path") unless term_keys.uniq == term_keys
      declared = []
      manifest["media"].each do |r|
        object!(r, %w[ref metadata rights display thumbnail width height])
        object!(r["metadata"], MediaAsset::METADATA)
        r["metadata"].each do |k, v|
          if k == "decorative"
            invalid!("decorative_boolean") unless [ true, false ].include?(v)
          else
            string!(v, { "title" => 200, "alt_text" => 500, "caption" => 2000 }.fetch(k, 1000))
          end
        end
        invalid!("missing_alternative_text") if !r["metadata"]["decorative"] && r["metadata"]["alt_text"].blank?
        object!(r["rights"], %w[status license attribution]); invalid!("uncleared_media_rights") unless r["rights"]["status"] == "cleared"
        %w[license attribution].each { |key| string!(r["rights"][key], 1000, empty: false) }
        %w[width height].each { |key| invalid!("media_dimensions") unless r[key].is_a?(Integer) && r[key].between?(1, 12_000) }
        %w[display thumbnail].each do |variant|
          info = r[variant]; object!(info, %w[sha256 bytes])
          invalid!("media_integrity") unless info["sha256"].is_a?(String) && SHA.match?(info["sha256"]) && info["bytes"].is_a?(Integer) && info["bytes"].between?(1, 12 * 1024 * 1024)
          name = "media/#{info['sha256']}.png"; bytes = payloads[name]
          invalid!("media_integrity") unless bytes && bytes.bytesize == info["bytes"] && Digest::SHA256.hexdigest(bytes) == info["sha256"]
          image = Railpress::ImageInput.inspect!(bytes)
          invalid!("media_type") unless image[:format] == "png"
          invalid!("media_dimensions") if variant == "display" && [ image[:width], image[:height] ] != r.values_at("width", "height")
          declared << name
        end
      end
      invalid!("undeclared_media") unless declared.uniq.sort == payloads.keys.sort
      paths = []
      manifest["content"].each do |r|
        object!(r, %w[ref working live history])
        history!(r["history"])
        snapshot!(r["working"], reference)
        snapshot!(r["live"], reference) if r["live"]
        invalid!("content_kind_changed") if r["live"] && r["live"]["type"] != r["working"]["type"]
        paths << Railpress::ContentRoutes.path(r["working"]["type"], r["working"]["slug"])
        invalid!("private_public_scope") if manifest["selection"] == "public" && (r["live"].nil? || r["working"] != r["live"] || r["working"]["visibility"] != "public" || r["history"]["state"] != "published")
      end
      invalid!("duplicate_content_path") unless paths.uniq == paths
      if site["homepage_ref"]
        homepage = manifest["content"].find { |r| r["ref"] == site["homepage_ref"] }
        invalid!("homepage_must_be_page") unless homepage["working"]["type"] == "Page"
      end
      revision_keys = []
      manifest["revisions"].each do |r|
        object!(r, %w[ref content_ref number event created_at snapshot history])
        reference.call(r["content_ref"], "content"); snapshot!(r["snapshot"], reference); history!(r["history"])
        timestamp!(r["created_at"]); string!(r["event"], 40, empty: false)
        invalid!("invalid_revision_number") unless r["number"].is_a?(Integer) && r["number"].positive?
        revision_keys << [ r["content_ref"], r["number"] ]
      end
      invalid!("duplicate_revision") unless revision_keys.uniq == revision_keys
      invalid!("private_history_in_public_export") if manifest["selection"] == "public" && manifest["revisions"].any?
      node_owners = {}
      manifest["menus"].each do |r|
        object!(r, %w[ref name draft live locations]); string!(r["name"], 100, empty: false)
        menu!(r["draft"], reference); menu!(r["live"], reference) if r["live"]
        (r["draft"] + Array(r["live"])).each do |node|
          invalid!("cross_menu_or_record_identity") if registry.key?(node["ref"]) || node_owners.key?(node["ref"]) && node_owners[node["ref"]] != r["ref"]
          node_owners[node["ref"]] = r["ref"]
        end
        list!(r["locations"], 20).each do |loc|
          object!(loc, %w[theme key draft live]); %w[theme key].each { |k| invalid!("invalid_location") unless loc[k].is_a?(String) && loc[k].match?(/\A[a-z][a-z0-9_\-]{0,39}\z/) }
          invalid!("location_boolean") unless [ loc["draft"], loc["live"] ].all? { |v| [ true, false ].include?(v) }
        end
        invalid!("private_menu_in_public_export") if manifest["selection"] == "public" && (r["draft"] != r["live"] || r["locations"].any? { |l| l["draft"] != l["live"] })
      end
      redirect_paths = []
      list!(manifest["redirects"], 2000).each do |r|
        object!(r, %w[path content_ref]); reference.call(r["content_ref"], "content")
        invalid!("unsafe_redirect_or_loop") unless Seo::RouteRegistry.redirect_source?(r["path"]) && !paths.include?(r["path"])
        redirect_paths << r["path"]
      end
      invalid!("duplicate_redirect") unless redirect_paths.uniq == redirect_paths
      appearance = manifest["appearance"]
      if appearance
        object!(appearance, %w[theme version digest api options media])
        %w[theme version].each { |k| string!(appearance[k], 80, empty: false) }
        invalid!("unsupported_theme_api") unless appearance["api"] == 1 && appearance["digest"].is_a?(String) && SHA.match?(appearance["digest"])
        object!(appearance["options"], %w[palette font layout footer home_pattern brand_label header_style footer_style appearance_mode artwork_style], required: [])
        if appearance["options"].key?("appearance_mode")
          invalid!("invalid_appearance_mode") unless appearance["theme"] == "dusk" && %w[light dark system].include?(appearance["options"]["appearance_mode"])
        end
        if appearance["options"].key?("artwork_style")
          invalid!("invalid_artwork_style") unless appearance["theme"] == "dusk" && %w[editorial none].include?(appearance["options"]["artwork_style"])
        end
        appearance["options"].each_value { |v| string!(v, 500) }
        object!(appearance["media"], %w[logo favicon], required: [])
        appearance["media"].each_value { |v| reference.call(v, "media") }
      end
      manifest
    rescue Seo::SiteOrigin::Invalid, TZInfo::InvalidTimezoneIdentifier, ContentBlocks::Schema::Invalid, Railpress::ImageInput::Invalid, Navigation::Mutation::Invalid => error
      invalid!("invalid_record: #{error.class.name}")
    end
    def history!(r)
      object!(r, %w[state created_at updated_at published_at first_published_at scheduled_at])
      invalid!("invalid_historical_state") unless Content::STATES.include?(r["state"])
      (r.keys - [ "state" ]).each { |k| timestamp!(r[k]) }
    end
    def snapshot!(r, reference)
      object!(r, SNAPSHOT)
      invalid!("content_kind_or_visibility") unless %w[Page Post].include?(r["type"]) && %w[public private].include?(r["visibility"]) && %w[standard wide].include?(r["template_key"]) && [ true, false ].include?(r["home_page"])
      { "title"=>200, "slug"=>160, "body"=>200_000, "excerpt"=>1000, "meta_title"=>160, "meta_description"=>320 }.each { |k, n| string!(r[k], n, empty: !%w[title slug].include?(k)) }
      invalid!("noncanonical_or_reserved_slug") unless Railpress::ContentRoutes.content_slug(r["type"], r["slug"]) == r["slug"] && !Railpress::ContentRoutes.reserved_content_slug?(r["type"], r["slug"])
      pattern = r["type"] == "Page" ? /\A[a-z0-9]+(?:-[a-z0-9]+)*(?:\/[a-z0-9]+(?:-[a-z0-9]+)*){0,2}\z/ : /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
      invalid!("invalid_slug") unless pattern.match?(r["slug"])
      invalid!("active_html") unless Editorial::RichText.clean(r["body"]) == r["body"]
      reference.call(r["author_ref"], "authors", true)
      list!(r["term_refs"], 30).each { |ref| reference.call(ref, "terms") }
      invalid!("duplicate_term_reference") unless r["term_refs"].uniq == r["term_refs"]
      reference.call(r["featured_media_ref"], "media", true)
      blocks = list!(r["blocks"], 40).map do |block|
        invalid!("invalid_block") unless block.is_a?(Hash)
        invalid!("native_media_identity_forbidden") if block.key?("media_id") || block.key?("media_ids")
        item = block.deep_dup
        if item.key?("media_ref")
          reference.call(item["media_ref"], "media", true); item["media_id"] = item.delete("media_ref") ? 1 : nil
        end
        if item.key?("media_refs")
          list!(item["media_refs"], 12).each { |ref| reference.call(ref, "media") }
          invalid!("duplicate_gallery_reference") unless item["media_refs"].uniq == item["media_refs"]
          item["media_ids"] = item.delete("media_refs").each_index.map { |i| i + 1 }
        end
        normalized = ContentBlocks::Schema.normalize([ item ]).first
        invalid!("noncanonical_block_or_unknown_field") unless normalized == item
        item
      end
      ContentBlocks::Schema.normalize(blocks)
      invalid!("invalid_per_use_media") unless r["media_details"].is_a?(Hash) && r["media_details"].length <= 64
      r["media_details"].each do |ref, details|
        reference.call(ref, "media"); object!(details, MediaAsset::METADATA + %w[width height sha256 public_id])
        details.each { |k, v| string!(v, 2000) if v.is_a?(String) }
        invalid!("invalid_per_use_description") unless [ true, false ].include?(details["decorative"]) && MediaAsset::METADATA.reject { |k| k == "decorative" }.all? { |k| details[k].is_a?(String) } && details["public_id"] == ref && details["sha256"].is_a?(String) && SHA.match?(details["sha256"]) && %w[width height].all? { |k| details[k].is_a?(Integer) && details[k].between?(1, 12_000) }
      end
      metadata!(r["portable_metadata"])
    end
    def menu!(rows, reference)
      list!(rows, 30); keys = rows.map { |r| r.is_a?(Hash) && r["ref"] }
      invalid!("duplicate_menu_node") unless keys.uniq == keys
      rows.each do |r|
        object!(r, %w[ref parent_ref position label kind target_ref url]); ref!(r["ref"]); string!(r["label"], 120, empty: false)
        invalid!("invalid_menu_parent") unless r["parent_ref"].nil? || keys.include?(r["parent_ref"])
        seen = [ r["ref"] ]; parent = r["parent_ref"]
        while parent
          invalid!("menu_cycle_or_depth") if seen.include?(parent) || seen.length >= 3
          seen << parent; parent = rows.find { |x| x["ref"] == parent }.fetch("parent_ref")
        end
        invalid!("menu_position") unless r["position"].is_a?(Integer) && r["position"].between?(0, 29)
        case r["kind"]
        when "Page", "Post" then reference.call(r["target_ref"], "content", false, r["kind"]); invalid!("menu_target_fields") unless r["url"].nil?
        when "Term" then reference.call(r["target_ref"], "terms"); invalid!("menu_target_fields") unless r["url"].nil?
        when "Custom" then Navigation::SafeUrl.validate!(r["url"]); invalid!("menu_target_fields") unless r["target_ref"].nil?
        else invalid!("menu_kind")
        end
      end
      rows.group_by { |r| r["parent_ref"] }.each_value { |siblings| invalid!("menu_order") unless siblings.map { |r| r["position"] }.sort == (0...siblings.length).to_a }
    end
  end
end
