require "test_helper"
require_relative "../support/installation_test_support"
require_relative "../support/membership_test_support"

class AmendedSiteIntegrationTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport

  setup do
    @old_providers = Rails.application.config.x.membership_provider_adapter
    @providers = MembershipTestSupport::SyntheticProviders.new
    Rails.application.config.x.membership_provider_adapter = @providers
  end
  teardown { Rails.application.config.x.membership_provider_adapter = @old_providers }

  %w[disabled email discord both].each do |mode|
    test "ordinary installer #{mode} preserves appearance privacy export and independent Owner recovery" do
      review_install
      advance_install(self, "membership", fields: { "membership_mode" => mode, "member_registration_enabled" => mode == "disabled" ? "0" : "1", "member_email_required" => "1" })
      post "/setup/complete", params: finish_params(csrf_token_for(self, "/setup"))
      assert_response :see_other
      @owner = User.find_by!(role: "owner")
      site = Site.first
      assert_equal mode, site.membership_mode
      assert_equal mode != "disabled", site.member_registration_enabled
      assert site.privacy_first_anonymous?
      assert_equal 0, Member.count
      private_post = Editorial::Workflow.create!(actor: @owner, kind: "Post", attributes: { "title" => "PRIVATE INTEGRATION CANARY", "slug" => "integration-private", "visibility" => "private" })
      token = UserSession.issue!(@owner)
      session = UserSession.resolve(token)
      package = ThemeState.first.active_installation
      immutable = Themes::Storage.load(package).files
      baseline = nil
      %w[light dark system].each do |appearance|
        overlay = Themes::Manager.overlay!(actor: @owner, installation: package, attributes: { appearance_mode: appearance, artwork_style: "editorial" })
        Themes::Manager.preview!(actor: @owner, installation: package, overlay: overlay, authentication_token: token)
        Themes::Manager.activate!(actor: @owner, installation: package, overlay: overlay, version: ThemeState.first.lock_version)
        guest = ActionDispatch::Integration::Session.new(Rails.application)
        guest.https!
        guest.get "/"
        assert_equal 200, guest.response.status
        assert_nil guest.response.headers["Set-Cookie"]
        assert_includes guest.response.headers["Content-Security-Policy"], "connect-src 'none'"
        doc = Nokogiri::HTML(guest.response.body)
        assert_equal appearance, doc.at_css("body")["data-dusk-appearance"]
        assert doc.at_css("picture source[srcset]"), "generated responsive artwork"
        assert_empty doc.css('body.core,iframe,img[src^="http"],script[src^="http"]')
        refute_includes guest.response.body, private_post.title
        head = doc.css('link[rel="canonical"],meta[name="robots"],script[type="application/ld+json"]').map(&:to_html)
        baseline ||= head
        assert_equal baseline, head
        guest.get "/blog/#{private_post.slug}"
        assert_equal 404, guest.response.status
        assert_nil guest.response.headers["Set-Cookie"]
      end
      assert_equal immutable, Themes::Storage.load(package).files
      sign_in
      get "/admin"
      assert_response :ok
      assert_select "body.core.admin-shell", count: 1
      assert_select 'link[href*="protected_dark"]', count: 1
      assert_select "img.brand-mark[src=?]", CoreBrandHelper::MARK, minimum: 1
      assert_select "body[data-dusk-appearance]", count: 0

      if %w[email both].include?(mode)
        Membership::EmailVerification.request!(browser: "a" * 64, address: "reader@example.invalid", client: "synthetic-integration")
        member, credential = Membership::EmailVerification.complete!(browser: "a" * 64, token: @providers.messages.last.fetch(:token))
        assert_equal member, MemberSession.resolve(credential).member
        refute Identity::Capabilities.allowed?(member, :admin)
      end
      if %w[discord both].include?(mode)
        url = Membership::Discord.start!(browser: "b" * 64, client: "synthetic-integration")
        reply = @providers.authorize(url, { "id" => "987654321012345678", "email" => "discord-reader@example.invalid", "verified" => true })
        member, credential = Membership::Discord.complete!(**reply, browser: "b" * 64, callback: site.canonical_origin + "/login/members/discord/callback")
        assert_equal member, MemberSession.resolve(credential).member
        refute Identity::Capabilities.allowed?(member, :admin)
      end
      assert_equal [ "owner" ], User.pluck(:role)
      scope = { "mode" => "public", "content_ids" => [], "history" => false, "author_labels" => {}, "media_rights" => {}, "menus" => true, "appearance" => true }
      export = Portability::Exports.request!(actor: @owner, session_id: session.id, scope: scope)
      Portability::Exports.perform!(export)
      manifest, = Railpress::SiteArchive.read(Portability::Store.read(export))
      assert_equal 3, manifest["version"]
      assert manifest["site"]["privacy_first_anonymous"]
      assert_equal "system", manifest["appearance"]["options"]["appearance_mode"]
      refute manifest["site"].key?("membership_mode")
      refute_includes manifest.to_json, private_post.title
      refute_includes manifest.to_json, "reader@example.invalid"
      refute_includes manifest.to_json, "SYNTHETIC-NOT-A-LIVE-SECRET"
      recovery = create_recovery_token
      assert recovery
      next_password = "synthetic-recovered-owner-2026!"
      Identity::PasswordRecovery.complete!(token: recovery, password: next_password, confirmation: next_password)
      assert_nil UserSession.resolve(token)
      assert @owner.reload.authenticate(next_password)
      assert @owner.owner?
      assert_equal mode, site.reload.membership_mode
      assert site.privacy_first_anonymous?
      assert_equal "system", ThemeState.first.active_overlay.options["appearance_mode"]
    end
  end
end
