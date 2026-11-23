# frozen_string_literal: true

module Installation
  module Starter
    module_function
    def call(owner:, site:, choices:)
      home = page(owner, "Welcome", "welcome", "<p>Your website is ready. Edit this welcome page to tell visitors what you do and how you can help.</p>", home: true)
      pages = [ home ]
      pages << page(owner, "About", "about", "<p>Add your story here. Replace this starter text with accurate information about you or your organization.</p>") if choices["about"]
      pages << page(owner, "Contact", "contact", "<p>Add your preferred contact details here before sharing this page. No contact form or email delivery is configured by this starter.</p>") if choices["contact"]
      Editorial::Workflow.create!(actor: owner, kind: "Post", attributes: { "title" => "Your first story", "slug" => "your-first-story", "body" => "<p>Start writing here. This sample post stays a draft until you choose to publish it.</p>" })
      expected = Environment.candidate
      package = Themes::Manager.stage!(actor: owner, directory: ENV.fetch("RAILPRESS_INSTALL_THEME"), expected_digest: expected.digest)
      overlay = Themes::Manager.overlay!(actor: owner, installation: package, attributes: { "brand_label" => choices["brand_label"] })
      token = UserSession.issue!(owner)
      begin
        Themes::Manager.preview!(actor: owner, installation: package, overlay: overlay, authentication_token: token)
        Themes::Manager.activate!(actor: owner, installation: package, overlay: overlay, version: ThemeState.find_by!(site: site).lock_version)
      ensure
        ThemePreview.where(session_digest: Digest::SHA256.hexdigest(token)).delete_all
        UserSession.where(token_digest: Digest::SHA256.hexdigest(token)).delete_all
      end
      menu = mutate(owner, nil, "create", { "name" => "Main navigation" })
      pages.each { |content| menu = mutate(owner, menu, "add", { "item" => { "kind" => "Page", "content_id" => content.id, "label" => content.title } }) }
      menu = mutate(owner, menu, "assign", { "locations" => %w[dusk:primary dusk:mobile dusk:footer] })
      mutate(owner, menu, "publish", {})
      raise Progress::Invalid, "Starter navigation did not publish." unless menu.reload.published_revision_id
      true
    end

    def page(owner, title, slug, body, home: false)
      content = Editorial::Workflow.create!(actor: owner, kind: "Page", attributes: { "title" => title, "slug" => slug, "body" => body, "home_page" => home })
      Editorial::Workflow.update!(actor: owner, content: content, expected_version: content.lock_version, event: "publish")
    end

    def mutate(owner, menu, operation, payload)
      Navigation::Mutation.call(actor: owner, menu: menu, expected_version: menu&.reload&.lock_version,
        expected_state: Navigation::Mutation.generation(Site.find_by!(singleton_key: 1)), operation: operation, payload: payload)
    end
  end
end
