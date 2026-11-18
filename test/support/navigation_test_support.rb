require_relative "theme_test_support"
require_relative "public_request_observation"
require Rails.root.join("lib/railpress/dusk_package")
module NavigationTestSupport
  extend ActiveSupport::Concern
  include ThemeTestSupport
  include PublicRequestObservation
  included do
    # Menu presentation/transaction tests use a deterministic process clock.
    # Separate native-clock probes retain real SQL cutoffs and host observations.
    teardown do
      unless passed?
        observation = { trace: @qualification_request_trace, now: Time.current.iso8601(6),
          contents: Content.order(:id).pluck(:id, :type, :slug, :status, :published_visibility, :published_at),
          navigation_generation: Navigation::Mutation.generation(Site.find_by(singleton_key: 1)) }
        File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M08')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-menu-failure-#{SecureRandom.hex(4)}.json"), JSON.pretty_generate(observation) + "\n")
      end
      travel_back
    end
  end
  def menu_create(name = "Main navigation", actor: @owner)
    Navigation::Mutation.call(actor: actor, operation: "create", expected_state: nav_version, payload: { "name" => name })
  end
  def nav_version = Navigation::Mutation.generation(site)
  def mutate(menu, operation, payload = {}, actor: @owner, version: menu.reload.lock_version, state: nav_version)
    Navigation::Mutation.call(actor: actor, menu: menu, operation: operation, expected_version: version, expected_state: state, payload: payload)
  end
  def add_link(menu, label, url = "/search")
    mutate(menu, "add", { "item" => { "kind" => "Custom", "label" => label, "url" => url } })
  end
  def navigation_package
    directory = File.join(@private_root, "navigation-dusk-#{SecureRandom.hex(5)}")
    Railpress::DuskPackage.build(directory, root: Rails.root, signer: @signer)
    Themes::Manager.stage!(actor: @owner, directory: directory)
  end
  def nav_slots(preview: nil)
    Navigation::Renderer.call(site: site, theme_key: "dusk", declared: { "primary" => "Primary", "mobile" => "Mobile", "footer" => "Footer", "documentation" => "Documentation" }, preview: preview)
  end
  def assign_publish(menu, locations = [ "dusk:primary" ])
    mutate(menu, "assign", { "locations" => locations }); mutate(menu, "publish")
  end
  def ordered_tree(menu) = Navigation::Tree.ordered(menu.reload.tree)
  def evidence(name, value)
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M08')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-#{name}.json"), JSON.pretty_generate(value) + "\n")
  end
end
