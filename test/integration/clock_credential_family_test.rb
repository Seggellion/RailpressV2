require "test_helper"
require_relative "../support/navigation_test_support"
require_relative "../support/security_clock_test_support"

class ClockCredentialFamilyTest < ActionDispatch::IntegrationTest
  include NavigationTestSupport
  include SecurityClockTestSupport

  def credentials
    session_token = UserSession.issue!(@owner)
    reset_token = create_recovery_token
    item = draft(slug: "family-private")
    preview, preview_token = Editorial::Previews.issue!(actor: @owner, content: item)
    package = navigation_package
    activate(package)
    theme_token = Themes::Manager.preview!(actor: @owner, installation: package, overlay: package.theme_overlays.first, authentication_token: session_token)
    menu = menu_create
    add_link(menu, "Family private menu")
    mutate(menu, "assign", { "locations" => [ "dusk:primary" ] })
    navigation_token = Navigation::Preview.issue(actor: @owner, menu: menu, authentication_token: session_token)
    rows = [
      UserSession.find_by!(token_digest: Digest::SHA256.hexdigest(session_token)),
      PasswordReset.find_by!(token_digest: Digest::SHA256.hexdigest(reset_token)),
      preview,
      ThemePreview.find_by!(token_digest: Digest::SHA256.hexdigest(theme_token["token"])),
      NavigationPreview.find_by!(token_digest: Digest::SHA256.hexdigest(navigation_token["token"]))
    ]
    [ rows, { session: session_token, reset: reset_token, preview: preview_token, preview_id: preview.id, theme: theme_token, navigation: navigation_token } ]
  end

  test "all database credential families honor maximum elapsed lifetime without wall progress" do
    with_controlled_security_clock do |_clock, ticks|
      rows, _tokens = credentials
      rows.each { |row| assert row.deadline_valid?, row.class.name }
      matrix = []
      rows.sort_by { |row| row.class::LIFETIME }.each do |row|
        ticks[:value] = row.deadline_binding.fetch("deadline") + 0.1
        refute row.reload.deadline_valid?, row.class.name
        matrix << { family: row.class.name, maximum_seconds: row.class::LIFETIME.to_i, expired_without_wall_progress: true }
      end
      clock_evidence("credential-family-elapsed-matrix", matrix)
    end
  end

  test "all families reject a changed boot domain and legacy null bindings without renewing" do
    with_controlled_security_clock do |_clock, ticks|
      rows, _tokens = credentials
      expiries = rows.to_h { |row| [ row.class.name, row.expires_at ] }
      ticks[:domain] = "another-synthetic-boot-domain"
      rows.each { |row| refute row.reload.deadline_valid?, row.class.name }
      ticks[:domain] = "synthetic-supported-boot-domain"
      rows.each do |row|
        row.reload
        refute row.deadline_valid?
        assert_equal expiries.fetch(row.class.name), row.expires_at
      end
      assert UserSession.resolve(UserSession.issue!(@owner))
    end
  end

  test "explicit revocation and consumption cannot be undone by rollback" do
    rows, tokens = credentials
    UserSession.where(id: rows[0].id).delete_all
    rows[1].update!(used_at: Time.current)
    rows[2].destroy!
    rows[3].delete
    Navigation::Preview.revoke(actor: @owner, authentication_token: tokens[:session], credential: tokens[:navigation])
    travel(-5.seconds) do
      assert_nil UserSession.resolve(tokens[:session])
      assert_raises(Identity::PasswordRecovery::InvalidToken) { Identity::PasswordRecovery.complete!(token: tokens[:reset], password: PASSWORD, confirmation: PASSWORD) }
      assert_raises(ActiveRecord::RecordNotFound) { Editorial::Previews.resolve!(actor: @owner, id: tokens[:preview_id], token: tokens[:preview]) }
      assert_nil Themes::Selection.preview(@owner, tokens[:session], tokens[:theme])
      assert_nil Navigation::Preview.resolve(actor: @owner, authentication_token: tokens[:session], credential: tokens[:navigation])
    end
  end

  test "navigation resolve and revoke race terminates with durable denial" do
    _rows, tokens = credentials
    results = parallel_results(2) do |index|
      if index.zero?
        Navigation::Preview.resolve(actor: User.find(@owner.id), authentication_token: tokens[:session], credential: tokens[:navigation]) ? :resolved : :denied
      else
        Navigation::Preview.revoke(actor: @owner, authentication_token: tokens[:session], credential: tokens[:navigation])
        :revoked
      end
    end
    assert_includes results, :revoked
    travel(-3.seconds) { assert_nil Navigation::Preview.resolve(actor: @owner, authentication_token: tokens[:session], credential: tokens[:navigation]) }
  end
end
