require "net/http"
require "test_helper"
require_relative "../support/security_clock_test_support"
require_relative "../support/navigation_test_support"
class NavigationSafetyTest < ActionDispatch::IntegrationTest
  include SecurityClockTestSupport
  include NavigationTestSupport
  test "hidden parent suppresses descendants and custom same origin links cannot advertise private routes" do
    activate(navigation_package)
    page = change(draft("Page", slug: "public-guide"), "publish")
    menu = menu_create
    mutate(menu, "add", { "item" => { "kind" => "Page", "label" => "Parent label", "content_id" => page.id } })
    add_link(menu, "CHILD CANARY")
    child = ordered_tree(menu).last["key"]
    mutate(menu, "move", { "key" => child, "direction" => "indent" })
    add_link(menu, "Protected path", "/admin")
    add_link(menu, "Absolute protected path", "#{site.canonical_origin}/preview/1")
    add_link(menu, "External & safe", "https://example.invalid/useful")
    assign_publish(menu)
    observed_public_get "/"
    assert_select 'nav[aria-label="Primary"] a[href="https://example.invalid/useful"]', text: "External & safe"
    refute_includes response.body, "Protected path"
    refute_includes response.body, "Absolute protected path"
    assert_includes response.body, "CHILD CANARY"
    change(page, "unpublish")
    observed_public_get "/"
    refute_includes response.body, "CHILD CANARY"
    refute_includes response.body, "Parent label"
    observed_public_get "/public-guide"; assert_response :not_found
  end
  test "nested footer and documentation slots render every level with native disclosures" do
    activate(navigation_package)
    page = change(draft("Page", slug: "guide"), "publish")
    menu = menu_create
    mutate(menu, "add", { "item" => { "kind" => "Page", "label" => "Root", "content_id" => page.id } })
    %w[Branch Leaf].each { |label| add_link(menu, label) }
    rows = ordered_tree(menu)
    mutate(menu, "move", { "key" => rows[1]["key"], "direction" => "indent" })
    mutate(menu, "move", { "key" => rows[2]["key"], "direction" => "indent" })
    mutate(menu, "move", { "key" => rows[2]["key"], "direction" => "indent" })
    assign_publish(menu, %w[dusk:footer dusk:documentation])
    observed_public_get "/guide"; assert_response :ok
    [ "Footer", "Documentation" ].each do |slot|
      assert_select "nav[aria-label='#{slot}'] details[data-disclosure] summary", count: 2
      assert_select "nav[aria-label='#{slot}'] a[href='/search']", text: "Leaf"
    end
    assert_equal "/guide", Seo::RouteRegistry.content_path(page, site)
  end
  test "an intentionally empty header omits empty controls and footer disclosure still receives core enhancement" do
    activate(navigation_package)
    menu = menu_create("Empty header"); assign_publish(menu)
    footer = menu_create("Footer")
    add_link(footer, "Root"); add_link(footer, "Child")
    mutate(footer, "move", { "key" => footer.tree.last["key"], "direction" => "indent" })
    assign_publish(footer, [ "dusk:footer" ])
    observed_public_get "/"
    assert_response :ok
    assert_select ".dusk-desktop-nav,.dusk-mobile-nav", count: 0
    assert_select "footer details[data-disclosure]", count: 1
    assert_select "script[src]", count: 1
    script = Nokogiri::HTML(response.body).at_css("script[src]")
    assert_includes response.headers["Content-Security-Policy"], "'nonce-#{script['nonce']}'"
    mutate(footer, "assign", { "locations" => [] }); mutate(footer, "publish")
    observed_public_get "/"
    assert_select ".dusk-mobile-nav,script[src]", count: 0
    page = change(draft("Page", slug: "body-navigation"), "publish")
    mutate(footer, "add", { "item" => { "kind" => "Page", "label" => "Body navigation", "content_id" => page.id } })
    assign_publish(footer, [ "dusk:documentation" ])
    observed_public_get "/body-navigation"
    assert_response :ok
    assert_select ".dusk-mobile-nav,footer details[data-disclosure]", count: 0
    assert_select 'nav[aria-label="Documentation"] details[data-disclosure]', count: 1
    assert_select "script[src]", count: 1
    assert_equal "/body-navigation", Seo::RouteRegistry.content_path(page, site)
  end
  test "menu rendering has no remote cache or network dependency and invalidates after publish" do
    activate(navigation_package)
    menu = menu_create; add_link(menu, "Before cache failure"); assign_publish(menu)
    observed_public_get "/"; assert_includes response.body, "Before cache failure"
    row = menu.tree.first
    mutate(menu, "update", { "key" => row["key"], "item" => { "label" => "After cache failure" } })
    generation = site.reload.seo_generation
    with_method(Rails.cache, :read, ->(*) { raise "cache unavailable" }) do
      with_method(Rails.cache, :write, ->(*) { raise "cache unavailable" }) do
        with_method(Net::HTTP, :start, ->(*) { raise "navigation attempted HTTP" }) do
          mutate(menu, "publish")
          observed_public_get "/"
          assert_response :ok
          assert_includes response.body, "After cache failure"
          refute_includes response.body, "Before cache failure"
        end
      end
    end
    assert_operator site.reload.seo_generation, :>, generation
    evidence("navigation-failure-injection", { cache_read: "raises", cache_write: "raises", http_start: "raises if called", publication: "committed", public_result: response.status })
  end
  test "independent mobile footer and primary assignments switch atomically and undo does not steal later assignments" do
    activate(navigation_package)
    first = menu_create("Brochure"); add_link(first, "Brochure"); assign_publish(first, %w[dusk:primary dusk:footer])
    second = menu_create("Handheld"); add_link(second, "Handheld"); assign_publish(second, [ "dusk:mobile" ])
    assert_equal [ "Brochure" ], nav_slots.primary.map(&:label)
    assert_equal [ "Handheld" ], nav_slots.mobile.map(&:label)
    assert_equal [ "Brochure" ], nav_slots.footer.map(&:label)
    mutate(second, "assign", { "locations" => %w[dusk:primary dusk:mobile] })
    assert_equal [ "Brochure" ], nav_slots.primary.map(&:label)
    mutate(first, "publish")
    assert_equal [ "Brochure" ], nav_slots.primary.map(&:label)
    assert_equal second.id, MenuLocation.find_by!(theme_key: "dusk", key: "primary").draft_menu_id
    mutate(second, "publish")
    assert_equal [ "Handheld" ], nav_slots.primary.map(&:label)
    assert_equal [ "Brochure" ], nav_slots.footer.map(&:label)
    revision = second.menu_revisions.order(:number).last
    mutate(second, "undo", { "revision_id" => revision.id })
    assert_equal [ "Brochure" ], nav_slots.primary.map(&:label)
    mutate(first, "rename", { "name" => "Independent new name" })
    assert_raises(Navigation::Mutation::Conflict) { mutate(second, "undo", { "revision_id" => second.menu_revisions.order(:number).last.id }) }
  end
  test "actual administrator role revocation invalidates private preview immediately" do
    activate(navigation_package)
    admin = create_account("administrator")
    menu = menu_create; add_link(menu, "ADMIN PREVIEW CANARY"); mutate(menu, "assign", { "locations" => [ "dusk:primary" ] })
    sign_in(self, admin)
    csrf = csrf_token_for(self, edit_admin_menu_path(menu))
    post preview_admin_menu_path(menu), params: { authenticity_token: csrf }
    observed_public_get "/"; assert_includes response.body, "ADMIN PREVIEW CANARY"
    Identity::ManageUsers.change_role!(actor: @owner, user: admin, role: "editor")
    observed_public_get "/"; refute_includes response.body, "ADMIN PREVIEW CANARY"
    get edit_admin_menu_path(menu); assert_response :see_other
  end
  test "draft and published snapshots retain stable identities through equivalent pointer and keyboard trees" do
    menu = menu_create; %w[One Two Three].each { |label| add_link(menu, label) }
    original = ordered_tree(menu)
    mutate(menu, "move", { "key" => original[2]["key"], "direction" => "up" })
    keyboard = ordered_tree(menu)
    mutate(menu, "undo", { "revision_id" => menu.menu_revisions.order(:number).last.id })
    pointer = original.values_at(0, 2, 1).each_with_index.map { |row, i| row.slice("key", "parent_key").merge("position" => i) }
    mutate(menu, "reorder", { "tree" => pointer })
    assert_equal keyboard, ordered_tree(menu)
    mutate(menu, "reparent", { "tree" => ordered_tree(menu).map.with_index { |row, i| row.slice("key", "parent_key", "position").merge("parent_key" => i == 1 ? original[0]["key"] : nil, "position" => i == 2 ? 1 : 0) } })
    assert_equal original[0]["key"], ordered_tree(menu)[1]["parent_key"]
    evidence("navigation-input-equivalence", { keyboard: keyboard, pointer: pointer, equivalent: true, browser_qualification: "separate actual Chrome evidence required" })
  end
  test "scheduled transitions and durable publication agree between navigation and canonical routes" do
    activate(navigation_package)
    base = Time.current.utc.change(usec: 0)
    page = nil; menu = nil
    travel_to(base, with_usec: true) do
      page = change(draft("Page", slug: "timed-guide"), "publish")
      menu = menu_create
      mutate(menu, "add", { "item" => { "kind" => "Page", "label" => "TIMED GUIDE", "content_id" => page.id } })
      assign_publish(menu)
    end
    matrix = []
    [ [ -0.5, 200, true ], [ 0.1, 200, true ] ].each do |offset, status, visible|
      travel_to(base + offset, with_usec: true) do
        observed_public_get "/timed-guide"; assert_equal status, response.status
        assert_equal visible, nav_slots.primary.any? { |item| item.label == "TIMED GUIDE" }
        matrix << { offset: offset, content_status: status, menu_visible: visible }
      end
    end
    travel_to(base + 1) do
      change(page, "unpublish")
      change(page, "schedule", attributes: { schedule_local: 2.hours.from_now.in_time_zone(site.timezone).strftime("%Y-%m-%dT%H:%M") })
      refute PublishContentJob.perform_now(page.id, page.lock_version)
      refute nav_slots.primary.any? { |item| item.label == "TIMED GUIDE" }
    end
    with_qualified_utc(base + 3.hours) do
      expected = page.lock_version
      accepted = PublishContentJob.perform_now(page.id, expected)
      clock_path = File.join(@private_root, "security-clock.json")
      clock_observation = JSON.parse(File.read(clock_path)).slice("wall", "elapsed", "generation", "anomaly")
      evidence("scheduled-navigation-clock-observation", { accepted: accepted, expected_version: expected,
        actual: page.reload.attributes.slice("status", "lock_version", "scheduled_at", "scheduled_by_id"),
        fixture_time: Time.current.iso8601(6), actual_elapsed: Process.clock_gettime(Process::CLOCK_BOOTTIME),
        clock: clock_observation, observation_only: true, clock_modified_by_observer: false })
      assert accepted
      assert nav_slots.primary.any? { |item| item.label == "TIMED GUIDE" }
      change(page.reload, "unpublish")
      refute nav_slots.primary.any? { |item| item.label == "TIMED GUIDE" }
    end
    evidence("navigation-clock-eligibility", { scope: "controlled Ruby application clock only; host unchanged", matrix: matrix, scheduled_early: false, due_visible: true, withdrawal_visible: false })
  end
  test "menu size invalid IDs malformed references and declared signed slots are bounded" do
    menu = menu_create
    assert_raises(Navigation::Mutation::Invalid) { mutate(menu, "add", { "item" => { "kind" => "Page", "label" => "Wrong", "content_id" => -1 } }) }
    assert_raises(Navigation::Mutation::Invalid) { mutate(menu, "add", { "item" => { "kind" => "Term", "label" => "Wrong", "term_id" => 999999 } }) }
    assert_raises(Navigation::Mutation::Invalid) { add_link(menu, "") }
    assert_raises(Navigation::Mutation::Invalid) { add_link(menu, "x" * 121) }
    assert_raises(Navigation::Mutation::Invalid) { add_link(menu, " " + "x" * 120 + " ") }
    assert_raises(Navigation::Mutation::Invalid) { add_link(menu, "\u00a0") }
    30.times { |i| add_link(menu, "Link #{i}") }
    assert_raises(Navigation::Mutation::Invalid) { add_link(menu, "Overflow") }
    assert_equal 30, menu.menu_items.count
    package = navigation_package
    assert_equal %w[documentation footer mobile primary], package.manifest.fetch("menu_locations").keys.sort
    invalid = package.manifest.deep_dup; invalid["menu_locations"]["admin"] = "Protected"
    assert_raises(Railpress::ThemePackage::Invalid) { Railpress::ThemePackage.manifest!(invalid) }
    invalid = package.manifest.deep_dup; invalid["menu_locations"]["primary"] = "<script>"
    assert_raises(Railpress::ThemePackage::Invalid) { Railpress::ThemePackage.manifest!(invalid) }
    assert_raises(Navigation::Mutation::Invalid) { mutate(menu, "assign", { "locations" => %w[dusk:primary dusk:primary] }) }
  end
end
