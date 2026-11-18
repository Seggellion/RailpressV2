module Navigation
  module Mutation
    class Invalid < StandardError; end
    class Conflict < StandardError; end
    module_function
    def require_managed!
      raise Invalid, "Use the transactional navigation service." unless ActiveSupport::IsolatedExecutionState[:navigation_mutation]
    end
    def state(site) = NavigationState.find_by(site: site)
    def generation(site) = state(site)&.lock_version || 0
    def declared(site)
      packages = ThemeInstallation.where(site: site, status: "validated").order(:id)
      packages = packages.lock if ActiveSupport::IsolatedExecutionState[:navigation_mutation]
      packages.each_with_object({}) do |package, result|
        (package.manifest["menu_locations"] || {}).each { |key, label| result["#{package.theme_key}:#{key}"] = label }
      end
    end
    def integer(value)
      raise Invalid, "Invalid revision." unless value.to_s.match?(/\A(?:0|[1-9][0-9]*)\z/)
      value.to_i
    end
    def call(actor:, menu: nil, expected_version: nil, expected_state:, operation:, payload: {})
      result = Site.transaction do
        site = Site.find_by!(singleton_key: 1); site.lock!
        raise Identity::Capabilities::Denied unless actor&.id
        actor = User.lock.find(actor.id)
        Identity::Capabilities.require!(actor, :manage_menus)
        nav_state = NavigationState.find_or_create_by!(site: site)
        nav_state.lock!
        raise Conflict, "Navigation changed in another editor. Compare your submitted changes and reload." unless nav_state.lock_version == integer(expected_state)
        ActiveSupport::IsolatedExecutionState[:navigation_mutation] = true
        if operation == "create"
          raise Invalid, "At most 20 active menus are supported." if Menu.where(site: site, status: "active").lock.limit(20).to_a.length >= 20
          menu = Menu.create!(site: site, name: payload.fetch("name"))
        else
          menu = Menu.where(site: site).lock.find(menu.id)
          raise Conflict, "This menu changed. Compare your submitted changes and reload." unless menu.lock_version == integer(expected_version)
          raise Invalid, "Restore this deleted menu with undo first." if menu.status == "deleted" && operation != "undo"
        end
        before = snapshot(menu, site)
        before["status"] = "deleted" if operation == "create"
        rows = menu.tree
        retained = rows.deep_dup
        publish = false
        case operation
        when "create" then nil
        when "import_tree"
          batch = ImportBatch.find_by(id: ActiveSupport::IsolatedExecutionState[Portability::Context::KEY]&.first)
          raise Identity::Capabilities::Denied unless batch
          Portability::Context.require!(batch)
          rows = payload.fetch("tree")
          retained = []
        when "rename" then menu.name = payload.fetch("name")
        when "add"
          raise Invalid, "Add one typed target at a time." unless payload["item"].is_a?(Hash)
          item = payload["item"].slice(*Tree::FIELDS).except("key", "parent_key", "position")
          rows << item.merge("key" => SecureRandom.hex(16), "parent_key" => nil, "position" => rows.count { |row| row["parent_key"].nil? })
        when "update"
          row = rows.find { |item| item["key"] == payload["key"] } || raise(Invalid, "Unknown menu item.")
          row.merge!(payload.fetch("item").slice("label", "kind", "content_id", "term_id", "url"))
        when "remove"
          key = payload.fetch("key")
          raise Invalid, "Unknown menu item." unless rows.any? { |row| row["key"] == key }
          removed = [ key ]
          loop do
            children = rows.select { |row| removed.include?(row["parent_key"]) }.map { |row| row["key"] }
            break if (children - removed).empty?
            removed |= children
          end
          rows.reject! { |row| removed.include?(row["key"]) }; Tree.normalize!(rows)
        when "reorder", "reparent"
          proposed = payload.fetch("tree")
          raise Invalid, "Submit the complete item ID set exactly once." unless proposed.is_a?(Array) && proposed.all? { |row| row.is_a?(Hash) && row["key"].is_a?(String) } && proposed.length == rows.length && proposed.map { |row| row["key"] }.sort == rows.map { |row| row["key"] }.sort
          index = rows.index_by { |row| row["key"] }
          rows = proposed.map do |row|
            raise Invalid, "Only item ID, parent and position may be reordered." unless (row.keys - %w[key parent_key position]).empty?
            index.fetch(row["key"]).merge(row)
          end
        when "move" then move!(rows, payload.fetch("key"), payload.fetch("direction"))
        when "assign"
          assign!(site, menu, payload.fetch("locations"))
        when "publish" then publish = true
        when "undo"
          previous = menu.menu_revisions.order(number: :desc).lock.first
          raise Conflict, "Undo is unavailable after another menu changed. Reload and make an explicit edit." unless previous && previous.state_version == nav_state.lock_version && previous.id == integer(payload["revision_id"])
          old = previous.before_snapshot
          menu.name = old.fetch("name"); menu.status = old.fetch("status")
          menu.published_revision_id = old["published_revision_id"]
          rows = old.fetch("tree"); retained += rows
          restore_locations!(site, old.fetch("locations"))
        when "delete"
          menu.status = "deleted"; menu.published_revision_id = nil
          MenuLocation.where(site: site, draft_menu_id: menu.id).update_all(draft_menu_id: nil)
          MenuLocation.where(site: site, published_menu_id: menu.id).update_all(published_menu_id: nil)
        else raise Invalid, "Unknown navigation operation."
        end
        Tree.validate!(rows, retained: retained)
        write_tree!(menu, rows)
        nav_state.updated_at_will_change!
        nav_state.update!(updated_at: Time.current)
        revision = menu.menu_revisions.create!(actor: actor, number: menu.lock_version + 1, state_version: nav_state.lock_version, operation: operation, before_snapshot: before, snapshot: { "name" => menu.name, "tree" => Tree.ordered(rows) })
        if publish
          menu.published_revision = revision
          MenuLocation.where(site: site).where("draft_menu_id = ? OR published_menu_id = ?", menu.id, menu.id).lock.each do |location|
            # Another menu's draft claim cannot withdraw this menu's live placement.
            next if location.draft_menu_id && location.draft_menu_id != menu.id
            location.update!(published_menu_id: location.draft_menu_id == menu.id ? menu.id : nil)
          end
        end
        menu.updated_at_will_change!
        menu.save!
        Seo::Invalidation.bump!
        Activity::Recorder.record!(actor: actor, action: "menu.#{operation}", subject: menu, details: { revision: revision.number })
        menu
      ensure
        ActiveSupport::IsolatedExecutionState.delete(:navigation_mutation)
      end
      Seo::Invalidation.after_commit!
      result
    rescue KeyError, TypeError, ActiveRecord::RecordInvalid => error
      raise Invalid, error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.join(". ") : "Incomplete navigation command."
    end
    def snapshot(menu, site)
      { "name" => menu.name, "status" => menu.status, "tree" => menu.tree, "published_revision_id" => menu.published_revision_id,
        "locations" => MenuLocation.where(site: site).order(:theme_key, :key).lock.map { |row| row.attributes.slice("theme_key", "key", "draft_menu_id", "published_menu_id") } }
    end
    def assign!(site, menu, values)
      allowed = declared(site)
      raise Invalid, "Choose each declared location at most once." unless values.is_a?(Array) && values.uniq == values && (values - allowed.keys).empty?
      MenuLocation.where(site: site, draft_menu_id: menu.id).update_all(draft_menu_id: nil)
      values.each do |value|
        theme_key, key = value.split(":", 2)
        MenuLocation.lock.find_or_initialize_by(site: site, theme_key: theme_key, key: key).update!(draft_menu: menu)
      end
    end
    def restore_locations!(site, rows)
      MenuLocation.where(site: site).delete_all
      rows.each { |row| MenuLocation.create!(row.merge("site_id" => site.id)) }
    end
    def write_tree!(menu, rows)
      Tree.ordered(menu.tree).reverse_each { |row| MenuItem.where(menu: menu, key: row["key"]).delete_all }
      Tree.ordered(rows).each { |row| MenuItem.create!(row.merge("menu_id" => menu.id, "parent_scope" => row["parent_key"] || "root")) }
    end
    def move!(rows, key, direction)
      row = rows.find { |item| item["key"] == key } || raise(Invalid, "Unknown menu item.")
      siblings = rows.select { |item| item["parent_key"] == row["parent_key"] }.sort_by { |item| item["position"] }
      index = siblings.index(row)
      case direction
      when "up", "down"
        other = siblings[index + (direction == "up" ? -1 : 1)] if direction == "down" || index.positive?
        raise Invalid, "This item cannot move further." unless other
        row["position"], other["position"] = other["position"], row["position"]
      when "indent"
        raise Invalid, "Indent needs a previous sibling." unless index.positive?
        row["parent_key"] = siblings[index - 1]["key"]
        row["position"] = rows.count { |item| item["parent_key"] == row["parent_key"] }
      when "outdent"
        parent = rows.find { |item| item["key"] == row["parent_key"] } || raise(Invalid, "This is already a root item.")
        rows.select { |item| item["parent_key"] == parent["parent_key"] && item["position"] > parent["position"] }.each { |item| item["position"] += 1 }
        row["parent_key"] = parent["parent_key"]; row["position"] = parent["position"] + 1
      else raise Invalid, "Unknown move."
      end
      Tree.normalize!(rows)
    end
  end
end
