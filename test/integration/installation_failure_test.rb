require "test_helper"
require_relative "../support/installation_test_support"

class InstallationFailureTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport

  def replacing(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name, replacement)
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end

  def prepared_claim(state = @state)
    prepare_install_schema
    claim = state.claim!(state.issue!)
    wizard = Installation::Wizard.new(state)
    wizard.start!(claim)
    Installation::Progress::STEPS[0...-1].each do |step|
      wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: step, fields: install_fields(step))
    end
    [ claim, wizard ]
  end

  test "nonempty unrelated schema is refused with table and rows intact" do
    @state.issue!
    c = ActiveRecord::Base.connection
    c.create_table(:m10_unrelated_canary) { |t| t.string :marker }
    c.execute("INSERT INTO m10_unrelated_canary (marker) VALUES ('PRESERVE')")
    assert_raises(Installation::DatabaseProbe::Unsafe) { Installation::DatabaseProbe.call }
    assert_raises(Installation::DatabaseProbe::Unsafe) { Installation::Schema.prepare!(state: @state, confirmation: Installation::Configuration.fingerprint) }
    assert_equal "PRESERVE", c.select_value("SELECT marker FROM m10_unrelated_canary")
    refute Installation::Schema.ready?(@state)
  ensure
    c&.drop_table(:m10_unrelated_canary, if_exists: true) # Only this test-created canary, on the verified synthetic target.
  end

  test "real interrupted DDL journals forward review and refuses retained unknown tables" do
    @state.issue!
    c = ActiveRecord::Base.connection
    failure_context = ActiveRecord::MigrationContext.new(Rails.root.join("test/support/failure_migrations"), ActiveRecord::Base.connection_pool.schema_migration)
    replacing(ActiveRecord::Base.connection_pool, :migration_context, -> { failure_context }) do
      assert_raises(Installation::Schema::Refused) { Installation::Schema.prepare!(state: @state, confirmation: Installation::Configuration.fingerprint) }
    end
    assert_equal "review_required", Installation::Schema.receipt(@state)["state"]
    refute Installation::Schema.ready?(@state)
    retained = c.table_exists?(:m01_failure_probe)
    assert_equal ENV.fetch("RAILPRESS_TEST_ENGINE") == "mysql2", retained
    refute_includes ActiveRecord::Base.connection_pool.schema_migration.versions, "20261111999999"
    if retained
      assert_raises(Installation::DatabaseProbe::Unsafe) { Installation::Schema.prepare!(state: @state, confirmation: Installation::Configuration.fingerprint) }
      assert c.table_exists?(:m01_failure_probe), "installer must retain and refuse partial DDL"
      c.drop_table(:m01_failure_probe) # Explicit cleanup of only this injected synthetic canary.
    end
    Installation::Schema.prepare!(state: @state, confirmation: Installation::Configuration.fingerprint)
    assert Installation::Schema.ready?(@state)
    assert_equal Installation::Schema.versions, ActiveRecord::Base.connection_pool.schema_migration.versions.sort
  ensure
    c&.drop_table(:m01_failure_probe, if_exists: true)
  end

  test "missing schema confirmation and symlinked receipt are refused" do
    @state.issue!
    assert_raises(Installation::Schema::Refused) { Installation::Schema.prepare!(state: @state, confirmation: "wrong") }
    target = File.join(@private_root, "untouched")
    File.write(target, "UNCHANGED", perm: 0o600)
    File.symlink(target, Installation::Schema.receipt_path(@state))
    assert_raises(Installation::Schema::Refused) { Installation::Schema.ready?(@state) }
    assert_equal "UNCHANGED", File.read(target)
  end

  test "SQL failure rolls back owner content theme and menus while allowing retry" do
    claim, wizard = prepared_claim
    replacing(Installation::Starter, :call, ->(**) { raise IOError, "synthetic starter interruption" }) do
      assert_raises(IOError) { Installation::Finish.call(state: @state, claim: claim, revision: wizard.progress.read["revision"]) }
    end
    [ Site, User, Content, ThemeInstallation, Menu ].each { |model| assert_equal 0, model.count }
    refute @state.installed?
    owner = Installation::Finish.call(state: @state, claim: claim, revision: wizard.progress.read["revision"])
    assert owner.owner?
    assert @state.installed?
    assert_equal 1, User.count
  end

  test "DB commit before private seal repairs only its own fully built attempt" do
    failing = Class.new(Railpress::BootstrapState) do
      attr_accessor :fail_seal
      private
      def persist(document)
        raise IOError, "synthetic seal failure" if fail_seal && document["status"] == "installed"
        super
      end
    end.new(@private_root)
    claim, wizard = prepared_claim(failing)
    failing.fail_seal = true
    assert_raises(IOError) { Installation::Finish.call(state: failing, claim: claim, revision: wizard.progress.read["revision"]) }
    owner_id = Site.first.owner_id
    assert_equal 1, User.count
    refute failing.installed?
    failing.fail_seal = false
    recovered = Installation::Finish.call(state: failing, claim: claim, revision: wizard.progress.read["revision"])
    assert_equal owner_id, recovered.id
    assert_equal 1, User.count
    assert failing.installed?
    assert_nil wizard.progress.read.dig("data", "owner")
  end

  test "remote unverified TLS and unsafe adapters are denied before connecting" do
    original = Installation::Configuration.active
    [ original.merge("host" => "169.254.169.254", "sslmode" => nil, "ssl_mode" => nil), original.merge("adapter" => "sqlite3") ].each do |config|
      replacing(Installation::Configuration, :active, -> { config }) do
        assert_raises(Installation::DatabaseProbe::Unsafe) { Installation::DatabaseProbe.call }
      end
    end
  end

  test "driver failures return redacted actionable errors without credentials" do
    adapter = Installation::Configuration.active["adapter"]
    method = adapter == "postgresql" ? :postgres : :mysql
    replacing(Installation::DatabaseProbe, method, ->(*) { raise IOError, "PASSWORD-CANARY" }) do
      error = assert_raises(Installation::DatabaseProbe::Unavailable) { Installation::DatabaseProbe.call }
      refute_includes error.message, "PASSWORD-CANARY"
      assert_nil error.cause
    end
  end

  test "schema checks never accept a cached empty row count" do
    @state.issue!
    c = ActiveRecord::Base.connection
    c.cache do
      assert_equal 0, c.select_value("SELECT COUNT(*) FROM #{c.quote_table_name('users')}").to_i
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { User.create!(owner_attributes.merge(role: "owner")) }
      end
      assert thread.join(10)
      assert_equal 0, c.select_value("SELECT COUNT(*) FROM #{c.quote_table_name('users')}").to_i, "control proves cached empty observation"
      assert_raises(Installation::Schema::Refused) { Installation::Schema.ensure_empty!(c) }
    end
  end
  test "real navigation validation refusal fails closed with actionable HTTP feedback" do
    csrf = review_install
    original = Navigation::Tree.method(:validate!)
    saw_reversal = false
    replacement = lambda do |rows, retained: []|
      if rows.any?
        saw_reversal = true
        raise Navigation::Mutation::Invalid, "synthetic validated target refusal"
      else
        original.call(rows, retained: retained)
      end
    end
    replacing(Navigation::Tree, :validate!, replacement) do
      post "/setup/complete", params: finish_params(csrf)
    end
    assert saw_reversal
    assert_response :unprocessable_entity
    assert_includes response.body, "Starter navigation visibility could not be verified"
    [ Site, User, Content, Menu, ThemeInstallation ].each { |model| assert_equal 0, model.count }
    refute @state.installed?
    get "/setup"
    assert_response :ok
    assert_select 'input[type="submit"][value="Create my website"]'
    assert_equal "review", Installation::Progress.new(@state).read["step"]
  end

  test "private JSON shape corruption fails safely without a database query" do
    @state.issue!
    File.write(File.join(@private_root, "installation.json"), "[]", perm: 0o600)
    assert_raises(Installation::Progress::Invalid) { Installation::Progress.new(@state).read }
    File.write(Installation::Schema.receipt_path(@state), "[]", perm: 0o600)
    assert_raises(Installation::Schema::Refused) { Installation::Schema.ready?(@state) }
    File.write(File.join(@private_root, "setup.json"), "[]")
    queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| queries << args.last[:sql] }
    get "/setup"
    assert_response :service_unavailable
    assert_empty queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end
end
