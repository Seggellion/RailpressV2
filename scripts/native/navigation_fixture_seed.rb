# M08 uses real transactional menu records; no navigation method override.
require Rails.root.join("scripts/native/dusk_fixture_seed")
site = Site.first
actor = User.first
mutate = lambda do |menu, operation, payload = {}|
  Navigation::Mutation.call(actor: actor, menu: menu, expected_version: menu&.reload&.lock_version,
    expected_state: Navigation::Mutation.generation(site), operation: operation, payload: payload)
end
main = mutate.call(nil, "create", { "name" => "Studio navigation" })
add = lambda do |menu, label, kind, target|
  item = { "label" => label, "kind" => kind }
  item[kind == "Custom" ? "url" : (kind == "Term" ? "term_id" : "content_id")] = target
  mutate.call(menu, "add", { "item" => item })
end
add.call(main, "Services", "Page", Page.find_by!(slug: "services").id)
add.call(main, "Studio", "Page", Page.find_by!(slug: "about").id)
add.call(main, "Guides", "Page", Page.find_by!(slug: "docs").id)
add.call(main, "Working together", "Page", Page.find_by!(slug: "docs").id)
add.call(main, "Latest story", "Post", Post.find_by!(slug: "note-1").id)
add.call(main, "Field notes", "Term", Term.find_by!(slug: "field-notes").id)
add.call(main, "Journal", "Custom", "/blog")
add.call(main, "Contact", "Page", Page.find_by!(slug: "contact").id)
rows = main.reload.tree
by_label = rows.index_by { |row| row["label"] }
rows = Navigation::Tree.ordered(rows).map { |row| row.slice("key", "parent_key", "position") }
[ "Guides", "Latest story", "Field notes" ].each_with_index do |label, index|
  row = rows.find { |item| item["key"] == by_label.fetch(label)["key"] }; row["parent_key"] = by_label.fetch("Studio")["key"]; row["position"] = index
end
leaf = rows.find { |item| item["key"] == by_label.fetch("Working together")["key"] }; leaf["parent_key"] = by_label.fetch("Guides")["key"]; leaf["position"] = 0
rows.select { |row| row["parent_key"].nil? }.each_with_index { |row, index| row["position"] = index }
mutate.call(main, "reorder", { "tree" => rows })
mutate.call(main, "assign", { "locations" => [ "dusk:primary" ] }); mutate.call(main, "publish")
footer = mutate.call(nil, "create", { "name" => "Helpful links" })
add.call(footer, "Privacy", "Page", Page.find_by!(slug: "privacy").id)
add.call(footer, "Working together", "Page", Page.find_by!(slug: "docs").id)
mutate.call(footer, "assign", { "locations" => %w[dusk:footer dusk:documentation] }); mutate.call(footer, "publish")
info_path = ENV.fetch("RAILPRESS_DUSK_FIXTURE_INFO")
info = JSON.parse(File.read(info_path)); info["menu_id"] = main.id; info["footer_menu_id"] = footer.id
File.write(info_path, JSON.generate(info), perm: 0o600)
puts "Real M08 menus staged and published through authoritative service"
