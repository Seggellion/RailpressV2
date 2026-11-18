require "test_helper"
require_relative "../support/installation_test_support"
require_relative "../support/membership_test_support"
class MembershipInstallerTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport
  setup do
    @prior_adapter = Rails.application.config.x.membership_provider_adapter
    @providers = MembershipTestSupport::SyntheticProviders.new
    Rails.application.config.x.membership_provider_adapter = @providers
  end
  teardown { Rails.application.config.x.membership_provider_adapter = @prior_adapter }
  test "installer exposes all four choices independently of first Owner and defaults closed" do
    %w[disabled email discord both].each do |mode|
      choices = Installation::Wizard.new(@state).validate("membership", { "membership_mode" => mode })
      assert_equal mode, choices["membership_mode"]
      refute choices["member_registration_enabled"]
    end
    @providers.email_ready = false
    assert_raises(Installation::Progress::Invalid) { Installation::Wizard.new(@state).validate("membership", { "membership_mode" => "email", "member_registration_enabled" => "1" }) }
    assert_equal "email", Installation::Wizard.new(@state).validate("membership", { "membership_mode" => "email", "member_registration_enabled" => "0" })["membership_mode"]
    assert_equal 0, User.count
    assert_equal 0, Member.count
  end
  test "complete browser wizard preserves selected policy with local Owner and no Member enrollment" do
    review_install
    fields = { "membership_mode" => "both", "member_registration_enabled" => "1", "member_email_required" => "1" }
    advance_install(self, "membership", fields: fields)
    get "/setup"
    assert_includes response.body, "both"
    refute_includes response.body, "SYNTHETIC-NOT-A-LIVE-SECRET"
    post "/setup/complete", params: finish_params(csrf_token_for(self, "/setup"))
    assert_response :see_other
    assert_equal "both", Site.first.membership_mode
    assert Site.first.member_registration_enabled
    assert_equal 1, User.count
    assert_equal 0, Member.count
    assert User.first.owner?
    get "/setup"
    assert_response :gone
  end
  test "provider readiness loss at finish stops safely and allows disabled completion" do
    review_install
    advance_install(self, "membership", fields: { "membership_mode" => "discord", "member_registration_enabled" => "1" })
    @providers.discord_ready = false
    post "/setup/complete", params: finish_params(csrf_token_for(self, "/setup"))
    assert_response :unprocessable_entity
    assert_equal 0, Site.count
    assert_equal 0, User.count
    refute @state.installed?
    advance_install(self, "membership", fields: { "membership_mode" => "discord", "member_registration_enabled" => "0" })
    post "/setup/complete", params: finish_params(csrf_token_for(self, "/setup"))
    assert_response :see_other
    refute Site.first.member_registration_enabled
    assert User.first.owner?
  end
end
