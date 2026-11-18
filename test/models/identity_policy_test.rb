require "test_helper"

class IdentityPolicyTest < ActiveSupport::TestCase
  include IdentityTestSupport
  setup { install_site! }

  test "normalized identities are unique and invalid roles fail the database constraint" do
    assert_raises(ActiveRecord::RecordNotUnique) { User.create!(owner_attributes("OWNER").merge(email: "different@example.invalid", role: "author")) }
    assert_raises(ActiveRecord::RecordNotUnique) { User.create!(owner_attributes("different").merge(email: @owner.email.upcase, role: "author")) }
    assert_raises(ActiveRecord::StatementInvalid) { @owner.update_column(:role, "superuser") }
    assert_equal 1, User.count
  end

  test "site validates origins locales IANA timezones and homepage preferences" do
    site = Site.first
    %w[http://example.invalid https://user:pass@example.invalid https://example.invalid/path https://example.invalid?query=1 https://example.invalid#fragment].each do |origin|
      site.canonical_origin = origin
      refute site.valid?
    end
    site.reload
    site.locale = "arbitrary"
    refute site.valid?
    site.reload
    site.timezone = "Arbitrary/Timezone"
    refute site.valid?
    site.reload
    site.home_mode = "executable"
    refute site.valid?
    site.reload
    site.timezone = "America/Vancouver"
    assert site.valid?
    assert_equal "America/Vancouver", site.timezone
  end

  test "password boundaries and confirmation are enforced" do
    %w[short].each do |password|
      user = User.new(owner_attributes("bad").merge(role: "author", password: password, password_confirmation: password))
      refute user.valid?
    end
    user = User.new(owner_attributes("bytes").merge(role: "author", password: "🔒" * 19, password_confirmation: "🔒" * 19))
    refute user.valid?
    user = User.new(owner_attributes("confirm").merge(role: "author", password_confirmation: nil))
    refute user.valid?
  end

  test "own versus others content policy is enforced for four roles" do
    author = create_account("author")
    editor = create_account("editor")
    admin = create_account("administrator")
    assert Identity::Capabilities.can_edit_content?(author, author_id: author.id)
    refute Identity::Capabilities.can_edit_content?(author, author_id: @owner.id)
    [ @owner, editor, admin ].each { |user| assert Identity::Capabilities.can_edit_content?(user, author_id: author.id) }
    refute Identity::Capabilities.allowed?(author, :publish_others)
    refute Identity::Capabilities.allowed?(admin, :manage_users)
    refute Identity::Capabilities.allowed?(editor, :execute_seo)
  end

  test "direct role changes and removal cannot bypass owner service" do
    assert_raises(ActiveRecord::RecordNotSaved) { @owner.update!(role: "administrator") }
    assert_raises(ActiveRecord::RecordNotDestroyed) { @owner.destroy! }
    assert @owner.reload.owner?
    assert_raises(Identity::ManageUsers::LastOwner) { Identity::ManageUsers.change_role!(actor: @owner, user: @owner, role: "administrator") }
    assert_raises(Identity::ManageUsers::LastOwner) { Identity::ManageUsers.remove!(actor: @owner, user: @owner) }
  end

  test "owner transfer and role change revoke sessions and pending reset tokens" do
    other = create_account("owner", "second-owner")
    session_token = UserSession.issue!(@owner)
    reset = create_recovery_token
    Identity::ManageUsers.change_role!(actor: other, user: @owner, role: "author")
    assert_equal other.id, Site.first.owner_id
    assert_nil UserSession.resolve(session_token)
    assert_raises(Identity::PasswordRecovery::InvalidToken) { Identity::PasswordRecovery.complete!(token: reset, password: PASSWORD, confirmation: PASSWORD) }
    assert_equal 1, @owner.reload.auth_version
  end

  test "operator recovery requires matching installed identity and existing owner" do
    token = UserSession.issue!(@owner)
    assert_raises(Identity::OperatorRecovery::Refused) do
      Identity::OperatorRecovery.recover!(state: @state, install_id: SecureRandom.uuid, identifier: @owner.username, password: PASSWORD, confirmation: PASSWORD)
    end
    Identity::OperatorRecovery.recover!(state: @state, install_id: Site.first.install_id, identifier: @owner.username,
      password: "operator-recovered-password!", confirmation: "operator-recovered-password!")
    assert_nil UserSession.resolve(token)
    assert @owner.reload.authenticate("operator-recovered-password!")
    author = create_account("author")
    assert_raises(Identity::OperatorRecovery::Refused) do
      Identity::OperatorRecovery.recover!(state: @state, install_id: Site.first.install_id, identifier: author.username, password: PASSWORD, confirmation: PASSWORD)
    end
  end

  test "a newer recovery token invalidates the previous one" do
    first = create_recovery_token
    second = create_recovery_token
    assert_raises(Identity::PasswordRecovery::InvalidToken) { Identity::PasswordRecovery.complete!(token: first, password: PASSWORD, confirmation: PASSWORD) }
    Identity::PasswordRecovery.complete!(token: second, password: PASSWORD, confirmation: PASSWORD)
    assert PasswordReset.all.all?(&:used_at)
  end

  test "lost private completion marker cannot take over an existing site" do
    id = Site.first.install_id
    File.unlink(File.join(@private_root, "setup.json"))
    claim = @state.claim!(@state.issue!)
    assert_raises(Railpress::BootstrapState::Closed) do
      Setup::Complete.call(state: @state, claim: claim, site_attributes: site_attributes, owner_attributes: owner_attributes("attacker"))
    end
    assert_equal 1, User.count
    assert_equal id, @state.install_id
    assert @owner.reload.authenticate(PASSWORD)
  end
end
