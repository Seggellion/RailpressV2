require "test_helper"
require_relative "../support/navigation_test_support"
class NavigationMutationTest < ActiveSupport::TestCase
  include NavigationTestSupport
  test "all mutations require a fresh authorized actor and bypassed model writes fail" do
    menu = menu_create
    %w[rename add update remove reorder reparent move assign publish undo delete].each do |operation|
      assert_raises(Identity::Capabilities::Denied) { mutate(menu, operation, {}, actor: @editor) }
    end
    administrator = create_account("administrator")
    add_link(menu, "First")
    mutate(menu, "rename", { "name" => "Admin allowed" }, actor: administrator)
    assert_equal "Admin allowed", menu.reload.name
    stale_actor = User.find(administrator.id)
    Identity::ManageUsers.change_role!(actor: @owner, user: administrator, role: "editor")
    assert_raises(Identity::Capabilities::Denied) { mutate(menu, "publish", actor: stale_actor) }
    assert_raises(Navigation::Mutation::Invalid) { menu.update!(name: "Bypass") }
    assert_raises(Navigation::Mutation::Invalid) { menu.menu_items.create!(key: SecureRandom.hex(16), parent_scope: "root", position: 0, label: "Bad", kind: "Custom", url: "/") }
  end
  test "undo creation withdraws the new aggregate and unauthorized missing actor fails closed" do
    menu = menu_create
    mutate(menu, "undo", { "revision_id" => menu.menu_revisions.last.id })
    assert_equal "deleted", menu.reload.status
    mutate(menu, "undo", { "revision_id" => menu.menu_revisions.last.id })
    assert_equal "active", menu.reload.status
    assert_raises(Identity::Capabilities::Denied) { Navigation::Mutation.call(actor: nil, operation: "create", expected_state: nav_version, payload: { "name" => "No actor" }) }
  end
  test "complete position sets cycles cross menu parents and depth violations roll back" do
    menu = menu_create; 4.times { |i| add_link(menu, "Item #{i}") }
    rows = ordered_tree(menu); keys = rows.map { |row| row["key"] }
    other = menu_create("Other"); add_link(other, "Other")
    invalid = [
      rows.first(3), rows + [ rows.first ],
      rows.map.with_index { |row, i| row.slice("key", "parent_key", "position").merge("position" => i.zero? ? 1 : i) },
      rows.map { |row| row.slice("key", "parent_key", "position").merge("parent_key" => row["key"]) },
      rows.map.with_index { |row, i| row.slice("key", "parent_key", "position").merge("parent_key" => keys[(i + 1) % 4], "position" => 0) },
      rows.map.with_index { |row, i| row.slice("key", "parent_key", "position").merge("parent_key" => i.zero? ? nil : keys[i - 1], "position" => 0) },
      rows.map { |row| row.slice("key", "parent_key", "position").merge("parent_key" => other.tree.first["key"], "position" => 0) },
      rows.map { |row| row.slice("key", "parent_key", "position").merge("position" => "0") },
      [ nil ]
    ]
    before = menu.tree; version = menu.lock_version
    invalid.each do |tree|
      assert_raises(Navigation::Mutation::Invalid) { mutate(menu, "reorder", { "tree" => tree }) }
      assert_equal before, menu.reload.tree
      assert_equal version, menu.lock_version
    end
  end
  test "stable root ordering move reparent delete subtree and undo are server confirmed" do
    menu = menu_create; %w[One Two Three].each { |label| add_link(menu, label) }
    keys = ordered_tree(menu).map { |row| row["key"] }
    mutate(menu, "move", { "key" => keys[1], "direction" => "indent" })
    mutate(menu, "move", { "key" => keys[2], "direction" => "indent" })
    assert_equal [ nil, keys[0], keys[0] ], ordered_tree(menu).map { |row| row["parent_key"] }
    mutate(menu, "move", { "key" => keys[2], "direction" => "indent" })
    assert_equal keys[1], ordered_tree(menu).last["parent_key"]
    assert_raises(Navigation::Mutation::Invalid) { mutate(menu, "move", { "key" => keys[1], "direction" => "indent" }) }
    mutate(menu, "remove", { "key" => keys[1] })
    assert_equal [ "One" ], ordered_tree(menu).map { |row| row["label"] }
    revision = menu.menu_revisions.order(:number).last
    mutate(menu, "undo", { "revision_id" => revision.id })
    assert_equal keys, ordered_tree(menu).map { |row| row["key"] }
    assert_raises(ActiveRecord::ReadOnlyRecord) { revision.update!(operation: "fake") }
  end
  test "unsafe URL schemes credentials encoding and malformed URL inputs are rejected without network use" do
    menu = menu_create
    bad = [ "javascript:alert(1)", "data:text/html,bad", "//evil.invalid", "http://example.invalid", "https://user:pass@example.invalid", "/a\\b", "/x\nX:evil", "https://example.invalid/%0a", "/%252f%252fevil", "/%2fevil", "https://", "", "https://example.invalid bad" ]
    bad.each { |url| assert_raises(Navigation::Mutation::Invalid, url) { add_link(menu, "Bad", url) } }
    %w[/search / https://example.invalid/path?q=1#part https://127.0.0.1:443/].each { |url| add_link(menu, "Safe", url) }
    assert_equal 4, menu.menu_items.count
    assert_equal 4, nav_slots(preview: menu).primary.length if MenuLocation.where(draft_menu_id: menu.id).exists?
    evidence("navigation-url-safety", { rejected: bad, accepted: menu.tree.map { |row| row["url"] }, fetching: "none; strings only" })
  end
  test "simultaneous conflicting reorders have exactly one winner and no partial tree" do
    menu = menu_create; %w[One Two Three].each { |label| add_link(menu, label) }
    original = ordered_tree(menu); expected = menu.lock_version; generation = nav_version
    options = [ original.reverse, original.rotate ].map { |rows| rows.each_with_index.map { |row, index| row.slice("key", "parent_key").merge("position" => index) } }
    results = parallel_results(2) do |index|
      begin
        mutate(Menu.find(menu.id), "reorder", { "tree" => options[index] }, version: expected, state: generation)
        { result: "saved", writer: index }
      rescue Navigation::Mutation::Conflict
        { result: "conflict", writer: index }
      end
    end
    assert_equal %w[conflict saved], results.map { |row| row[:result] }.sort
    actual = Menu.uncached { ordered_tree(menu) }
    assert_equal options[results.find { |row| row[:result] == "saved" }[:writer]], actual.map { |row| row.slice("key", "parent_key", "position") }
    assert_equal [ 0, 1, 2 ], actual.map { |row| row["position"] }
    assert_equal expected + 1, menu.reload.lock_version
    evidence("navigation-concurrency", { starting_menu_revision: expected, starting_state: generation, results: results, final: actual, final_revision: menu.lock_version })
  end
  test "stale versions malformed commands and intervening undo cannot overwrite" do
    menu = menu_create; version = menu.lock_version; state = nav_version
    add_link(menu, "One")
    assert_raises(Navigation::Mutation::Conflict) { mutate(menu, "publish", version: version, state: state) }
    assert_raises(Navigation::Mutation::Conflict) { mutate(menu, "publish", version: version) }
    revision = menu.menu_revisions.last
    other = menu_create("Other")
    assert_raises(Navigation::Mutation::Conflict) { mutate(menu, "undo", { "revision_id" => revision.id }) }
    assert_equal 1, menu.menu_items.count
    assert_equal 0, other.menu_items.count
    assert_raises(Navigation::Mutation::Invalid) { mutate(menu, "assign", { "locations" => [ "dusk:head" ] }) }
  end
  test "a valid fresh mutation preserves peer edits despite an older caller transaction snapshot" do
    menu = menu_create; add_link(menu, "Before")
    key = menu.reload.tree.first["key"]
    ready = Queue.new; proceed = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Site.transaction do
          captured = Menu.find(menu.id).tree
          isolation = if ENV.fetch("RAILPRESS_TEST_ENGINE") == "mysql2"
            ActiveRecord::Base.connection.select_value("SELECT @@transaction_isolation")
          else
            ActiveRecord::Base.connection.select_value("SHOW transaction_isolation")
          end
          ready << { captured: captured, isolation: isolation }
          versions = proceed.pop
          result = Navigation::Mutation.call(actor: @owner, menu: Menu.find(menu.id), expected_version: versions[0], expected_state: versions[1], operation: "add", payload: { "item" => { "kind" => "Custom", "label" => "Added", "url" => "/search" } })
          { version: result.lock_version, initial: captured }
        end
      end
    end
    snapshot = ready.pop
    peer = mutate(menu, "update", { "key" => key, "item" => { "label" => "Committed peer edit" } })
    versions = [ peer.lock_version, nav_version ]
    proceed << versions
    raise "Concurrency timeout" unless worker.join(20)
    result = worker.value
    final = Menu.uncached { Menu.find(menu.id).tree }
    evidence("navigation-caller-snapshot", { snapshot: snapshot, accepted_versions: versions, result: result, final: final })
    assert_equal [ "Committed peer edit", "Added" ], final.sort_by { |row| row["position"] }.map { |row| row["label"] }
    assert_equal versions[0] + 1, result[:version]
  ensure
    worker&.kill if worker&.alive?
  end
  test "native constraints enforce root uniqueness typed ownership own parents and own publication" do
    first = menu_create; second = menu_create("Second")
    add_link(first, "Root"); add_link(second, "Other")
    row = first.menu_items.first; other = second.menu_items.first
    sql = ActiveRecord::Base.connection
    invalid = [
      "UPDATE menu_items SET parent_key = #{sql.quote(other.key)}, parent_scope = #{sql.quote(other.key)} WHERE id = #{row.id}",
      "UPDATE menu_items SET parent_key = #{sql.quote(row.key)}, parent_scope = #{sql.quote(row.key)} WHERE id = #{row.id}",
      "UPDATE menu_items SET position = -1 WHERE id = #{row.id}",
      "UPDATE menu_items SET kind = 'Page' WHERE id = #{row.id}",
      "UPDATE menus SET published_revision_id = #{second.menu_revisions.first.id} WHERE id = #{first.id}"
    ]
    invalid.each { |statement| assert_raises(ActiveRecord::StatementInvalid) { sql.execute(statement) } }
    add_link(first, "Second root")
    assert_raises(ActiveRecord::StatementInvalid) { first.menu_items.last.update_columns(position: 0) }
    assert_equal 2, first.menu_items.count
  end
end
