require "test_helper"

class IdentityConcurrencyTest < ActiveSupport::TestCase
  include IdentityTestSupport

  test "independent setup file locks still cannot create a second DB owner" do
    states = %w[first second].map { |name| Railpress::BootstrapState.new(File.join(@private_root, name)) }
    claims = states.map { |state| state.claim!(state.issue!) }
    outcomes = parallel_results(2) do |index|
      Setup::Complete.call(state: states[index], claim: claims[index], site_attributes: site_attributes, owner_attributes: owner_attributes("owner#{index}"))
      :installed
    rescue Railpress::BootstrapState::Closed
      :closed
    end
    assert_equal [ :closed, :installed ], outcomes.sort
    assert_equal 1, Site.count
    assert_equal 1, User.count
    assert Site.first.owner.owner?
  end

  test "singleton is enforced by native uniqueness and check constraints" do
    install_site!
    attributes = Site.first.attributes.except("id")
    assert_raises(ActiveRecord::RecordNotUnique) { Site.insert_all!([ attributes.merge("install_id" => SecureRandom.uuid) ]) }
    assert_raises(ActiveRecord::StatementInvalid) { Site.insert_all!([ attributes.merge("singleton_key" => 2, "install_id" => SecureRandom.uuid) ]) }
    assert_equal 1, Site.count
  end

  test "two owners concurrently demoting themselves retain exactly one owner" do
    install_site!
    second = create_account("owner", "second-owner")
    users = [ @owner, second ]
    tokens = users.to_h { |user| [ user.id, UserSession.issue!(user) ] }
    outcomes = parallel_results(2) do |index|
      user = User.find(users[index].id)
      Identity::ManageUsers.change_role!(actor: user, user: user, role: "administrator")
      :changed
    rescue Identity::ManageUsers::LastOwner, Identity::Capabilities::Denied
      :refused
    end
    assert_equal [ :changed, :refused ], outcomes.sort
    assert_equal 1, User.where(role: "owner").count
    assert Site.first.owner.owner?
    changed = User.find_by!(role: "administrator")
    assert_nil UserSession.resolve(tokens.fetch(changed.id))
  end

  test "two owners concurrently deleting themselves retain one valid owner" do
    install_site!
    second = create_account("owner", "second-owner")
    users = [ @owner, second ]
    outcomes = parallel_results(2) do |index|
      user = User.find(users[index].id)
      Identity::ManageUsers.remove!(actor: user, user: user)
      :removed
    rescue Identity::ManageUsers::LastOwner, Identity::Capabilities::Denied
      :refused
    end
    assert_equal [ :refused, :removed ], outcomes.sort
    assert_equal 1, User.count
    assert_equal 1, User.where(role: "owner").count
    assert Site.first.owner.owner?
  end

  test "a stale repeatable-read snapshot cannot authorize a demoted owner" do
    install_site!
    second = create_account("owner", "second-owner")
    ready = Queue.new
    proceed = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Site.transaction do
          Site.find_by!(singleton_key: 1)
          User.find(second.id)
          ready << true
          proceed.pop
          Identity::ManageUsers.create!(actor: second, attributes: owner_attributes("unauthorized").merge(role: "author"))
          :created
        end
      end
    rescue Identity::Capabilities::Denied
      :denied
    end
    ready.pop
    Identity::ManageUsers.change_role!(actor: @owner, user: second, role: "author")
    proceed << true
    assert thread.join(20)
    assert_equal :denied, thread.value
    refute User.exists?(username: "unauthorized")
  ensure
    thread&.kill if thread&.alive?
  end

  test "one password reset token can be consumed by only one concurrent request" do
    install_site!
    UserSession.issue!(@owner)
    token = create_recovery_token
    outcomes = parallel_results(2) do |index|
      password = "concurrent-replacement-#{index}!"
      Identity::PasswordRecovery.complete!(token: token, password: password, confirmation: password)
      index
    rescue Identity::PasswordRecovery::InvalidToken
      :refused
    end
    assert_equal 1, outcomes.count(:refused)
    winner = outcomes.find { |item| item.is_a?(Integer) }
    assert @owner.reload.authenticate("concurrent-replacement-#{winner}!")
    assert_equal 1, @owner.auth_version
    assert_equal 0, UserSession.count
    assert PasswordReset.first.used_at
  end

  test "durable throttle serializes its unique bucket under actual concurrency" do
    outcomes = parallel_results(4) do
      AuthenticationThrottle.consume?(scope: "concurrent", identity: "synthetic", limit: 2, window: 10.minutes)
    end
    assert_equal 2, outcomes.count(true)
    assert_equal 2, outcomes.count(false)
    assert_equal 1, AuthenticationThrottle.count
    assert_equal 2, AuthenticationThrottle.first.attempts
  end

  test "DB commit followed by journal failure repairs forward without replacing owner" do
    failing_class = Class.new(Railpress::BootstrapState) do
      attr_accessor :fail_completion
      private
      def persist(document)
        raise IOError, "synthetic journal interruption" if fail_completion && document["status"] == "installed"
        super
      end
    end
    state = failing_class.new(@private_root)
    claim = state.claim!(state.issue!)
    state.fail_completion = true
    assert_raises(IOError) do
      Setup::Complete.call(state: state, claim: claim, site_attributes: site_attributes, owner_attributes: owner_attributes)
    end
    assert_equal 1, Site.count
    assert_equal 1, User.count
    refute state.installed?
    state.fail_completion = false
    assert_raises(Railpress::BootstrapState::Closed) do
      Setup::Complete.call(state: state, claim: claim, site_attributes: site_attributes, owner_attributes: owner_attributes("replacement"))
    end
    assert state.installed?
    assert_equal Site.first.install_id, state.install_id
    assert_equal [ "owner" ], User.pluck(:username)
  end
  test "password reset between verification and session issuance cannot revive old credentials" do
    install_site!
    verified = Queue.new
    proceed = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        user = Identity::Authentication.authenticate(identifier: @owner.username, password: PASSWORD)
        verified << user.id
        proceed.pop
        UserSession.issue!(user)
        :issued
      end
    rescue UserSession::StaleIdentity
      :refused
    end
    assert_equal @owner.id, verified.pop
    Identity::Authentication.replace_password!(@owner, password: "current-owner-password!", confirmation: "current-owner-password!")
    proceed << true
    assert thread.join(20)
    assert_equal :refused, thread.value
    assert_equal 0, UserSession.count
    assert_nil Identity::Authentication.authenticate(identifier: @owner.username, password: PASSWORD)
    assert UserSession.resolve(UserSession.issue!(@owner.reload))
  ensure
    thread&.kill if thread&.alive?
  end

  test "reconciliation acquires private lock before database locks and rejects wrong identity" do
    install_site!
    observed = Queue.new
    proceed = Queue.new
    state_class = Class.new(Railpress::BootstrapState) do
      attr_accessor :observed, :proceed
      def reconcile!(id)
        super do
          observed << ActiveRecord::Base.connection.transaction_open?
          proceed.pop
          yield
        end
      end
    end
    state = state_class.new(@private_root)
    state.observed = observed
    state.proceed = proceed
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Identity::OperatorRecovery.reconcile!(state: state, install_id: @state.install_id)
      end
    end
    refute observed.pop, "operator must not hold DB locks while waiting for private lock"
    site = Site.first
    Site.transaction do
      site.lock!
      proceed << true
    end
    assert thread.join(20)
    thread.value
    assert_equal site.install_id, state.install_id
    assert_raises(Identity::OperatorRecovery::Refused) do
      Identity::OperatorRecovery.reconcile!(state: Railpress::BootstrapState.new(File.join(@private_root, "wrong")), install_id: SecureRandom.uuid)
    end
    assert_equal site.install_id, Site.first.install_id
  ensure
    thread&.kill if thread&.alive?
  end

  test "stale snapshot cannot consume a recovery token replaced by newer mail" do
    install_site!
    old = create_recovery_token
    ready = Queue.new
    proceed = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        PasswordReset.transaction do
          ready << PasswordReset.find_by!(token_digest: Digest::SHA256.hexdigest(old)).id
          proceed.pop
          Identity::PasswordRecovery.complete!(token: old, password: "stale-token-password!", confirmation: "stale-token-password!")
          :consumed
        end
      end
    rescue Identity::PasswordRecovery::InvalidToken
      :refused
    end
    assert_equal PasswordReset.first.id, ready.pop
    newer = create_recovery_token
    proceed << true
    assert thread.join(20)
    assert_equal :refused, thread.value
    assert @owner.reload.authenticate(PASSWORD)
    assert_nil PasswordReset.find_by!(token_digest: Digest::SHA256.hexdigest(newer)).used_at
  ensure
    thread&.kill if thread&.alive?
  end
end
