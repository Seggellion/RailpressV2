module Navigation
  module Renderer
    module_function
    def call(site:, theme_key:, declared:, preview: nil)
      at = Time.current
      locations = MenuLocation.where(site: site, theme_key: theme_key).includes(published_menu: :published_revision).index_by(&:key)
      values = declared.to_h do |key, _label|
        location = locations[key]
        menu = location&.published_menu
        rows = menu&.status == "active" ? menu.published_revision&.snapshot&.fetch("tree", []) || [] : []
        if preview
          rows = [] if menu&.id == preview.id
          rows = preview.tree if location&.draft_menu_id == preview.id
        end
        [ key, tree(rows, site, at) ]
      end
      # An unassigned location uses the established usable core fallback.
      primary = if locations["primary"]&.published_menu_id || (preview && locations["primary"]&.draft_menu_id)
        values.fetch("primary", [])
      else Themes::Navigation.fallback(site).primary
      end
      mobile = if locations["mobile"]&.published_menu_id || (preview && locations["mobile"]&.draft_menu_id)
        values.fetch("mobile", [])
      else primary
      end
      Themes::Navigation.slots(primary: primary, mobile: mobile, footer: values.fetch("footer", []), documentation: values.fetch("documentation", []))
    end
    def tree(rows, site, at)
      children = rows.group_by { |row| row["parent_key"] }
      walk = lambda do |parent|
        (children[parent] || []).sort_by { |row| row["position"] }.filter_map do |row|
          url = Destinations.resolve(row, site, at: at)
          # Suppress a hidden parent's complete subtree; never promote private labels.
          Themes::Navigation.link(label: row.fetch("label"), url: url, children: walk.call(row["key"])) if url
        end
      end
      walk.call(nil)
    end
  end
end
