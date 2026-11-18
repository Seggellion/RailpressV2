module Navigation
  module Tree
    FIELDS = %w[key parent_key position label kind content_id term_id url].freeze
    module_function
    def validate!(rows, retained: [])
      raise Mutation::Invalid, "A menu can contain at most 30 items." unless rows.is_a?(Array) && rows.length <= 30
      keys = rows.map { |row| row.is_a?(Hash) && row["key"] }
      raise Mutation::Invalid, "Duplicate or invalid item IDs." unless keys.uniq == keys && keys.all? { |key| key.is_a?(String) && key.match?(/\A[0-9a-f]{32}\z/) }
      by_key = rows.index_by { |row| row["key"] }
      rows.each do |row|
        raise Mutation::Invalid, "Unknown item fields." unless (row.keys - FIELDS).empty?
        label = row["label"]
        raise Mutation::Invalid, "Labels must contain 1–120 plain characters." unless label.is_a?(String) && label.valid_encoding? && label.present? && label.length.between?(1, 120) && !label.match?(/[\x00-\x1f\x7f]/)
        raise Mutation::Invalid, "Invalid parent or position." unless (row["parent_key"].nil? || by_key.key?(row["parent_key"])) && row["position"].is_a?(Integer) && row["position"].between?(0, 29)
        seen = [ row["key"] ]; parent = row["parent_key"]
        while parent
          raise Mutation::Invalid, "A menu cannot contain cycles or more than 3 levels." if seen.include?(parent) || seen.length >= 3
          seen << parent; parent = by_key.fetch(parent)["parent_key"]
        end
        previous = retained.any? { |old| old.values_at("key", "kind", "content_id", "term_id", "url") == row.values_at("key", "kind", "content_id", "term_id", "url") }
        case row["kind"]
        when "Page", "Post"
          raise Mutation::Invalid, "Choose a published public content target." unless row["content_id"].is_a?(Integer) && !row["term_id"] && !row["url"] &&
            Content.where(id: row["content_id"], type: row["kind"]).lock.exists? && (previous || Content.publicly_visible.where(id: row["content_id"]).lock.exists? || Portability::Context.staged_content?(row["content_id"]))
        when "Term"
          raise Mutation::Invalid, "Choose an existing taxonomy term." unless !row["content_id"] && !row["url"] && row["term_id"].is_a?(Integer) && Term.where(id: row["term_id"]).lock.exists?
        when "Custom"
          raise Mutation::Invalid, "Custom links cannot contain content references." if row["content_id"] || row["term_id"]
          SafeUrl.validate!(row["url"])
        else raise Mutation::Invalid, "Unknown target type."
        end
      end
      rows.group_by { |row| row["parent_key"] }.each_value do |siblings|
        raise Mutation::Invalid, "Every sibling position must occur exactly once, starting at zero." unless siblings.map { |row| row["position"] }.sort == (0...siblings.length).to_a
      end
      rows
    end
    def normalize!(rows)
      rows.group_by { |row| row["parent_key"] }.each_value { |siblings| siblings.sort_by { |row| row["position"] }.each_with_index { |row, index| row["position"] = index } }
      rows
    end
    def ordered(rows)
      children = rows.group_by { |row| row["parent_key"] }
      walk = lambda { |parent| (children[parent] || []).sort_by { |row| row["position"] }.flat_map { |row| [ row, *walk.call(row["key"]) ] } }
      walk.call(nil)
    end
  end
end
