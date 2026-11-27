# frozen_string_literal: true

require "test_helper"
require "railpress/native_host"
require_relative "../support/extension_test_support"

class ModuleForwardRepairTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include ExtensionTestSupport

  setup { prepare_extension_site }
  teardown { cleanup_extension_site }

  test "reviewed physical preconditions and full postconditions control scoped repair" do
    case_name = ENV.fetch("RAILPRESS_TEST_ENGINE") == "postgresql" ? "rerun_transactional" : "record_implicit_commit"
    check_repair(case_name)
  end

  test "a committed PostgreSQL step is adopted without running the migration again" do
    next unless ENV.fetch("RAILPRESS_TEST_ENGINE") == "postgresql"
    check_repair("adopt_committed")
  end

  private

  def check_repair(action)
    packaged, = stage_package(version: "1.0.0", migration_count: 2)
    candidate = load_extension_set([ packaged ])
    entry = candidate.entries.fetch(MODULE_ID)
    request = Extensions::Requests.submit!(actor: @extension_site.owner, selection: selection_for(entry))
    @w01_owns_scratch = true
    context = Ext::Migrations.context(entry)
    first, second = entry.manifest.migrations
    context.run(:up, first.fetch("version").to_i)
    [first, second].each_with_index do |migration, index|
      ExtensionMigrationRecord.create!(site: @extension_site, module_id: entry.id,
        version: migration["version"], sha256: migration["sha256"], state: index.zero? ? "applied" : "started")
    end
    repair = Railpress::NativeHost::ModuleRepair.new(entry)
    if action == "rerun_transactional"
      ActiveRecord::Base.transaction do
        context.run(:up, second["version"].to_i)
        @target = repair.observe(@extension_site)
        raise ActiveRecord::Rollback
      end
    else
      context.run(:up, second["version"].to_i)
      @target = repair.observe(@extension_site)
      context.schema_migration.delete_version(second["version"]) if action == "record_implicit_commit"
    end
    observed = repair.observe(@extension_site)
    plan = { "action" => action, "version" => second["version"], "migration_sha256" => second["sha256"],
      "receipt_sequence" => 0, "before_sha256" => Ext.digest(observed),
      "after_schema_sha256" => @target["schema_sha256"], "after_data_sha256" => @target["data_sha256"] }
    error = assert_raises(Railpress::NativeHost::Error) do
      repair.apply!(request, plan.merge("before_sha256" => "0" * 64))
    end
    assert_equal "module_repair_precondition", error.message
    assert_equal observed, repair.observe(@extension_site)
    error = assert_raises(Railpress::NativeHost::Error) do
      repair.apply!(request, plan.merge("after_data_sha256" => "0" * 64))
    end
    assert_equal "module_repair_postcondition", error.message
    assert_equal observed, repair.observe(@extension_site)
    outcome = repair.apply!(request, plan)
    assert_equal observed, outcome.fetch("before")
    assert_equal @target.values_at("schema_sha256", "data_sha256", "versions"), outcome.fetch("after").values_at("schema_sha256", "data_sha256", "versions")
    assert Ext::Migrations.applied?(site: @extension_site, entry: entry)
    assert_equal "awaiting_operator", request.reload.state
    assert_not ExtensionInstallation.exists?(site: @extension_site)
    error = assert_raises(Railpress::NativeHost::Error) { repair.apply!(request, plan) }
    assert_equal "module_repair_ledger", error.message
    assert_equal outcome.fetch("after"), repair.observe(@extension_site)
  end
end
