require "test_helper"
require_relative "../support/extension_test_support"
require_relative "../support/administration_test_support"

class ExtensionInstallationTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include ExtensionTestSupport
  include AdministrationTestSupport

  setup { prepare_extension_site }
  teardown { cleanup_extension_site }

  test "Owner forms require CSRF and an exact fresh request without starting executable work" do
    row, = stage_package(version: "1.0.0")
    candidate = load_extension_set([ row ])
    selection = selection_for(candidate.entries.fetch(MODULE_ID))
    get "/admin/modules"
    assert_response :see_other
    %w[administrator editor author].each do |role|
      client = open_session
      client.https!
      sign_in(client, create_account(role))
      client.get("/admin/modules")
      assert_equal 403, client.response.status
    end
    sign_in
    csrf = csrf_token_for(self, "/admin/modules")
    post "/admin/modules", params: { selection: selection }
    assert_response :unprocessable_entity
    assert_empty ExtensionInstallRequest.all
    post "/admin/modules", params: { selection: selection, authenticity_token: csrf }
    assert_response :see_other
    request = ExtensionInstallRequest.sole
    assert_equal "awaiting_operator", request.state
    assert_equal @owner.auth_version, request.actor_auth_version
    assert_equal @extension_site.canonical_origin, request.site_origin
    get "/admin/modules"
    assert_includes response.body, "Awaiting operator installation"
    post "/admin/modules", params: { selection: selection, authenticity_token: csrf }
    assert_response :see_other
    assert_equal request.request_key, ExtensionInstallRequest.sole.request_key
    post "/admin/modules", params: { selection: selection.merge(version: "1.1.0"), authenticity_token: csrf }
    assert_response :conflict
    assert_empty ExtensionInstallation.all
    assert_invalid "extension_receipt_binding" do
      accept(request, candidate, "verifying", 1, request_sha256: "a" * 64)
    end
    assert_invalid "extension_receipt_time" do
      accept(request, candidate, "verifying", 1, issued_at: Time.now.to_i - 301)
    end
    assert_invalid "extension_operator_unconfigured" do
      accept(request, Ext::Registry.empty, "verifying", 1)
    end
    @owner.update!(auth_version: @owner.auth_version + 1)
    assert_raises(Identity::Capabilities::Denied) { accept(request, candidate, "verifying", 1) }
    assert_equal "awaiting_operator", request.reload.state
  end

  test "an unresolved Core switch blocks new module requests without reserving their identity" do
    row, = stage_package(version: "1.0.0")
    candidate = load_extension_set([ row ])
    switch = ReleaseRequest.create!(site: @extension_site, actor: @owner, actor_auth_version: @owner.auth_version,
      operation: "promote", release_digest: "a" * 64, request_key: SecureRandom.uuid)
    entry = candidate.entries.fetch(MODULE_ID)
    assert_invalid("extension_core_switch_pending") { submit(entry) }
    assert_empty ExtensionInstallRequest.all
    switch.destroy!
    assert_equal "awaiting_operator", submit(entry).state
    with_method(Releases::HostStatus, :operations, %w[promote]) do
      error = assert_raises(ArgumentError) do
        Releases::Requests.submit!(actor: @owner, operation: "promote", release_id: "a" * 64, request_id: SecureRandom.uuid)
      end
      assert_match(/module operation is pending/, error.message)
      assert_empty ReleaseRequest.all
    end
  end

  test "actual Rails children share exact engine identity and enable disable re-enable gates routes and new work" do
    row, = stage_package(version: "1.0.0")
    candidate = load_extension_set([ row ])
    entry = candidate.entries.fetch(MODULE_ID)
    request = submit(entry)
    @w01_owns_scratch = true

    assert_invalid("extension_migration_request") { apply_extension_migrations(request, candidate) }
    receipt = receipt_for(request, candidate, "verifying", 1)
    2.times do
      accepted = Extensions::Requests.accept!(request_key: request.request_key, registry: candidate, envelope: receipt)
      assert_equal "verifying", accepted.state
    end
    assert_invalid("extension_receipt_replay") { accept(request, candidate, "held", 1) }
    assert_equal "migrating", accept(request, candidate, "migrating", 2).state
    core_state = core_migration_state
    apply_extension_migrations(request, candidate)
    assert_equal core_state, core_migration_state
    assert Ext::Migrations.applied?(site: @extension_site, entry: entry)
    assert_equal [ 20261126001000 ], Ext::Migrations.context(entry).get_all_versions
    assert_equal "restarting", accept(request, candidate, "restarting", 3).state

    web = process_probe(<<~RUBY)
      begin
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.https!
        session.get("/extensions/neutral-probe")
        [session.response.status, NeutralProbe::Engine.isolated?, registry.reserved?("/extensions/neutral-probe/")]
      end
    RUBY
    worker = native_worker_probe
    assert_equal [ 404, true, true ], web.fetch("probe")
    assert_equal 0, record_count
    assert_equal candidate.fingerprint, web.fetch("fingerprint")
    assert_equal candidate.fingerprint, worker.fetch("fingerprint")
    assert_not_equal web.fetch("pid"), worker.fetch("pid")
    processes = { "web" => web.except("probe"), "worker" => worker }
    assert_invalid "extension_process_identity" do
      accept(request, candidate, "installed", 4, processes: processes.merge("worker" => processes["web"]), module_schema: 1, job_revision: 1)
    end
    assert_equal "installed", accept(request, candidate, "installed", 4, processes: processes, module_schema: 1, job_revision: 1).state
    refute ExtensionInstallation.sole.enabled
    assert_equal 0, record_count

    redirect = Redirect.create!(source_path: "/extensions/neutral-probe")
    assert_invalid("extension_route_collision") { change_activation(candidate, true, 1) }
    redirect.destroy!
    assert_equal [ 422, 303, 200 ], activate_with_owner_http(1)
    assert ExtensionInstallation.sole.enabled
    assert_invalid("extension_activation_stale") { change_activation(candidate, false, 1) }
    live = process_probe(<<~RUBY)
      begin
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.https!
        session.get("/extensions/neutral-probe")
        public_result = [session.response.status, session.response.body, session.response.headers["x-robots-tag"]]
        session.get("/admin/modules/neutral-probe/manage")
        unauthorized = session.response.status
        session.post("/extensions/neutral-probe")
        [public_result, unauthorized, session.response.status]
      end
    RUBY
    assert_equal [ [ 200, "Neutral probe", "noindex, nofollow" ], 403, 405 ], live.fetch("probe")
    assert_equal candidate.fingerprint, native_worker_probe.fetch("fingerprint")
    assert_equal 1, record_count
    refute change_activation(candidate, false, 2).enabled
    assert_equal candidate.fingerprint, native_worker_probe.fetch("fingerprint")
    assert_equal 1, record_count
    assert change_activation(candidate, true, 3).enabled
    assert Extensions::Activation.enabled?(MODULE_ID, registry: candidate)

    upgraded = upgrade_to(candidate, "1.1.0", activation: 4, module_schema: 2)
    assert_equal core_state, core_migration_state
    assert_equal 1, record_count
    assert_equal 2, Ext::Migrations.context(upgraded.entries.fetch(MODULE_ID)).get_all_versions.size
    revert = load_extension_set([ row ], previous: upgraded)
    revert_request = submit(revert.entries.fetch(MODULE_ID), previous: upgraded, activation: 5, operation: "revert")
    accept(revert_request, revert, "verifying", 1)
    accept(revert_request, revert, "restarting", 2)
    proof = process_evidence
    assert_invalid("extension_data_or_jobs_window") do
      accept(revert_request, revert, "installed", 3, processes: proof, module_schema: 1, job_revision: 1)
    end
    accept(revert_request, revert, "installed", 3, processes: proof, module_schema: 2, job_revision: 1)
    refute ExtensionInstallation.sole.enabled
    assert_equal 1, record_count

    empty = load_extension_set([], previous: revert)
    removal = submit(revert.entries.fetch(MODULE_ID), previous: revert, activation: 6, operation: "uninstall")
    accept(removal, empty, "verifying", 1)
    accept(removal, empty, "restarting", 2)
    empty_proof = process_evidence
    assert_invalid "extension_retention_hold" do
      accept(removal, empty, "retained", 3, processes: empty_proof, module_schema: 2, job_revision: 1)
    end
    accept(removal, empty, "retained", 3, processes: empty_proof, module_schema: 2, job_revision: 1, retention_clear: true)
    assert_equal "retained", ExtensionInstallation.sole.package_state
    assert_equal 1, record_count
  end

  test "interrupted DDL and changed applied bytes require a recovery hold on the exact synthetic adapter" do
    row, = stage_package(version: "1.0.0")
    initial = load_extension_set([ row ])
    @w01_owns_scratch = true
    request = submit(initial.entries.fetch(MODULE_ID))
    accept(request, initial, "verifying", 1)
    accept(request, initial, "migrating", 2)
    apply_extension_migrations(request, initial)
    core_state = core_migration_state
    accept(request, initial, "restarting", 3)
    accept(request, initial, "installed", 4, processes: process_evidence, module_schema: 1, job_revision: 1)

    original_path = "db/migrate/20261126001000_create_neutral_probe_records.rb"
    altered_source = Rails.root.join("test/fixtures/extensions/neutral_probe", original_path).read + "\n# Changed fixture bytes\n"
    altered, = stage_package(version: "1.1.0", migration_count: 2, file_changes: { original_path => altered_source })
    altered_registry = load_extension_set([ altered ], previous: initial)
    changed = submit(altered_registry.entries.fetch(MODULE_ID), previous: initial, activation: 1, operation: "upgrade")
    accept(changed, altered_registry, "verifying", 1)
    accept(changed, altered_registry, "migrating", 2)
    assert_invalid("extension_migration_digest") { apply_extension_migrations(changed, altered_registry) }
    assert_equal 1, ExtensionMigrationRecord.count
    accept(changed, altered_registry, "failed", 3)

    broken, = stage_package(version: "1.2.0", migration_count: 3)
    broken_registry = load_extension_set([ broken ], previous: initial)
    pending = submit(broken_registry.entries.fetch(MODULE_ID), previous: initial, activation: 1, operation: "upgrade")
    accept(pending, broken_registry, "verifying", 1)
    accept(pending, broken_registry, "migrating", 2)
    assert_invalid("extension_migration_recovery_required") { apply_extension_migrations(pending, broken_registry) }
    assert_equal %w[applied applied recovery_required], ExtensionMigrationRecord.order(:version).pluck(:state)
    assert_invalid("extension_migration_recovery_required") { apply_extension_migrations(pending, broken_registry) }
    connection = ActiveRecord::Base.connection
    assert connection.column_exists?(:rp_ext_neutral_probe_records, :status)
    assert_equal ENV["RAILPRESS_TEST_ENGINE"] == "mysql2", connection.column_exists?(:rp_ext_neutral_probe_records, :recovery_probe)
    assert_equal core_state, core_migration_state
    assert_invalid("extension_migration_recovery_required") { accept(pending, broken_registry, "failed", 3) }
    assert_equal "recovery_required", accept(pending, broken_registry, "recovery_required", 3).state
    assert_equal "1.0.0", ExtensionInstallation.sole.version
  end

  private

  def assert_invalid(code, &block)
    assert_equal code, assert_raises(Ext::Invalid, &block).message
  end

  def activate_with_owner_http(generation)
    process_probe(<<~RUBY).fetch("probe")
      begin
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.https!
        csrf = -> { Nokogiri::HTML(session.response.body).at_css('meta[name="csrf-token"]')["content"] }
        session.get("/login")
        session.post("/login", params: { identifier: #{@owner.username.inspect}, password: #{IdentityTestSupport::PASSWORD.inspect}, authenticity_token: csrf.call })
        session.get("/admin/modules")
        token = csrf.call
        path = "/admin/modules/neutral-probe/enable"
        session.patch(path, params: { generation: #{generation} })
        csrf_denial = session.response.status
        session.patch(path, params: { generation: #{generation}, authenticity_token: token })
        activated = session.response.status
        session.get("/admin/modules/neutral-probe/manage")
        [csrf_denial, activated, session.response.status]
      end
    RUBY
  end

  def submit(entry, previous: Ext::Registry.empty, activation: 0, operation: "install")
    Extensions::Requests.submit!(actor: @owner, registry: previous,
      selection: selection_for(entry, previous: previous, activation: activation, operation: operation))
  end

  def upgrade_to(previous, version, activation:, module_schema:)
    row, = stage_package(version: version, migration_count: 2)
    candidate = load_extension_set([ row ], previous: previous)
    request = submit(candidate.entries.fetch(MODULE_ID), previous: previous, activation: activation, operation: "upgrade")
    accept(request, candidate, "verifying", 1)
    accept(request, candidate, "migrating", 2)
    apply_extension_migrations(request, candidate)
    accept(request, candidate, "restarting", 3)
    accept(request, candidate, "installed", 4, processes: process_evidence, module_schema: module_schema, job_revision: 1)
    candidate
  end

  def core_migration_state
    connection = ActiveRecord::Base.connection
    versions = ActiveRecord::Base.connection_pool.migration_context.get_all_versions.sort
    key = connection.quote_column_name("key")
    metadata = connection.select_all("SELECT * FROM ar_internal_metadata ORDER BY #{key}").to_a
    [ versions, metadata ]
  end

  def record_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM rp_ext_neutral_probe_records").to_i
  end
end
