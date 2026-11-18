require "test_helper"
require_relative "../support/native_host_test_support"

class NativeSchemaTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include NativeHostTestSupport
  setup do
    install_site!
    native_setup
    @schema = Railpress::NativeHost::Schema.new(@native_config)
    @version = "20990101000001"
    @column = "extension_m12_qualification"
    @plan = { "format" => "railpress.expand.v1", "migration_version" => @version,
      "schema_from" => 11, "schema_to" => 12, "write_contract" => 12, "jobs_read" => [ 1, 1 ], "jobs_write" => [ 1, 1 ],
      "steps" => [ { "kind" => "add_nullable_column", "table" => "contents", "column" => @column, "type" => "string" },
        { "kind" => "backfill_copy", "table" => "contents", "column" => @column, "source" => "title", "batch" => 1 } ] }
  end
  teardown do
    if @native_db
      @native_db.execute("ALTER TABLE contents DROP COLUMN #{@native_db.quote_identifier(@column)}") if @native_db.column?("contents", @column)
      @native_db.execute("DELETE FROM schema_migrations WHERE version='#{@version}'")
      reset_schema_fixture_connections
    end
    native_teardown
  end
  def reset_schema_fixture_connections
    Content.reset_column_information
    # Removing a test-only column changes SELECT * result types. Reset every
    # pooled session, not just the active connection's prepared statement cache.
    ActiveRecord::Base.connection_pool.disconnect!
  end
  test "temporary schema cleanup leaves expired previews denied on every pooled connection" do
    page=Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title"=>"Schema cache boundary", "slug"=>"schema-cache-boundary" })
    preview, secret=Editorial::Previews.issue!(actor: @owner, content: page)
    @schema.apply!(@plan, progress: ->(_row) { })
    assert @native_db.column?("contents", @column)
    reset_schema_fixture_connections
    outcome=Queue.new
    prime=Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        actor=User.find(@owner.id)
        result=Editorial::Previews.resolve!(actor: actor, id: preview.id, token: secret)
        outcome<<{ visible: result.id==preview.id }
      end
    rescue StandardError=>error
      outcome<<{ error: error.class.name }
    end
    prime.join
    primed=outcome.pop
    assert primed[:visible], "Control: an authorized preview must resolve before the temporary column is removed (#{primed[:error]})"
    @native_db.execute("ALTER TABLE contents DROP COLUMN #{@native_db.quote_identifier(@column)}")
    reset_schema_fixture_connections
    travel_to(preview.expires_at+0.25, with_usec: true) do
      denied=Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          actor=User.find(@owner.id)
          Editorial::Previews.resolve!(actor: actor, id: preview.id, token: secret)
          outcome<<{ visible: true }
        end
      rescue StandardError=>error
        outcome<<{ error: error.class.name, visible: false }
      end
      denied.join
      observation=outcome.pop
      assert_equal "ActiveRecord::RecordNotFound", observation[:error]
      refute observation[:visible]
    end
    refute @native_db.column?("contents", @column)
  end
  test "real additive expansion and interrupted backfill resume without repeating applied work" do
    3.times { |n| Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title" => "Expansion #{n}", "slug" => "expansion-#{n}", "body" => "<p>Original body.</p>" }) }
    observed = []
    interrupted = false
    error = assert_raises(Railpress::NativeHost::Error) do
      @schema.apply!(@plan, progress: ->(row) { observed << row }, fault: ->(point) {
        if point == "backfill_batch" && !interrupted
          interrupted = true
          raise Railpress::NativeHost::Error, "injected_backfill_interruption"
        end
      })
    end
    assert_equal "injected_backfill_interruption", error.message
    assert @native_db.column?("contents", @column)
    assert_equal 1, @native_db.query("SELECT id FROM contents WHERE #{@native_db.quote_identifier(@column)} IS NOT NULL").length
    assert_empty @native_db.query("SELECT version FROM schema_migrations WHERE version='#{@version}'")
    result = @schema.apply!(@plan, progress: ->(row) { observed << row })
    refute result["partial"]
    assert_equal 3, @native_db.query("SELECT id FROM contents WHERE #{@native_db.quote_identifier(@column)}=title").length
    assert @schema.apply!(@plan, progress: ->(_row) { flunk })["already_applied"]
    assert_equal 3, ContentRevision.count
    assert_equal 1, Site.count
  end
  test "real SQL failure after successful DDL leaves the column unstamped and permits forward repair" do
    page = Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title" => "Partial DDL survivor", "slug" => "partial-ddl-survivor", "body" => "<p>Preserved original.</p>" })
    broken = @plan.deep_dup
    broken["steps"][1]["source"] = "name"
    error = assert_raises(StandardError) { @schema.apply!(broken, progress: ->(_row) { }) }
    assert_match(/name|column/i, error.message)
    assert @native_db.column?("contents", @column)
    assert_empty @native_db.query("SELECT version FROM schema_migrations WHERE version='#{@version}'")
    assert_equal "Partial DDL survivor", page.reload.title
    result = @schema.apply!(@plan, progress: ->(_row) { })
    refute result["partial"]
    assert_equal page.title, @native_db.query("SELECT #{@native_db.quote_identifier(@column)} FROM contents WHERE id=#{page.id}").first[@column]
    assert_equal 1, @native_db.query("SELECT version FROM schema_migrations WHERE version='#{@version}'").length
    assert_equal @owner.id, Site.first.owner_id
  end
  test "partial DDL persists honestly and a conflicting existing type cannot be silently adopted" do
    @native_db.execute("ALTER TABLE contents ADD COLUMN #{@native_db.quote_identifier(@column)} BIGINT NULL")
    error = assert_raises(Railpress::NativeHost::Error) { @schema.apply!(@plan, progress: ->(_row) { }) }
    assert_equal "partial_schema_mismatch", error.message
    assert_empty @native_db.query("SELECT version FROM schema_migrations WHERE version='#{@version}'")
    assert_equal @owner.id, Site.first.owner_id
  end
  test "arbitrary SQL destructive contraction and credential backfill plans are rejected" do
    variants = []
    variants << @plan.deep_dup.tap { |p| p["schema_to"] = 10 }
    variants << @plan.deep_dup.tap { |p| p["steps"][0]["kind"] = "drop_table" }
    variants << @plan.deep_dup.tap { |p| p["steps"][0]["table"] = "users" }
    variants << @plan.deep_dup.tap { |p| p["steps"][0]["column"] = "title" }
    variants << @plan.deep_dup.tap { |p| p["steps"][0]["table"] = "contents; DROP TABLE users" }
    variants << @plan.deep_dup.tap { |p| p["steps"][1]["source"] = "password_digest" }
    variants.each { |plan| assert_raises(Railpress::NativeHost::Error) { @schema.validate!(plan) } }
    refute @native_db.column?("contents", @column)
    assert_equal 1, User.count
  end
  test "code revert considers actual schema write job and security windows" do
    manifest = { "compatibility" => { "schema_read" => [ 11, 12 ], "schema_write" => [ 11, 12 ],
      "jobs_read" => [ 1, 1 ], "jobs_write" => [ 1, 1 ], "security_clock" => 2, "theme_api" => 1 } }
    contract = { "schema" => 12, "write" => 12, "jobs" => 1, "theme_api" => 1 }
    assert @schema.revert_eligible!(manifest, contract)
    %w[schema write jobs theme_api].each do |field|
      invalid = contract.merge(field => 99)
      assert_raises(Railpress::NativeHost::Error) { @schema.revert_eligible!(manifest, invalid) }
    end
    manifest["compatibility"]["security_clock"] = 1
    assert_raises(Railpress::NativeHost::Error) { @schema.revert_eligible!(manifest, contract) }
  end
  test "a compatible old writer after expansion can be backfilled again without a second stamp" do
    @schema.apply!(@plan, progress: ->(_row) { })
    page = Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title" => "Old writer after expansion", "slug" => "old-writer-expansion", "body" => "<p>Existing compatible writer.</p>" })
    assert_nil @native_db.query("SELECT #{@native_db.quote_identifier(@column)} FROM contents WHERE id=#{page.id}").first[@column]
    observed = []
    result = @schema.apply!(@plan, progress: ->(row) { observed << row })
    assert result["already_applied"]
    assert_equal page.title, @native_db.query("SELECT #{@native_db.quote_identifier(@column)} FROM contents WHERE id=#{page.id}").first[@column]
    assert_equal 1, @native_db.query("SELECT version FROM schema_migrations WHERE version='#{@version}'").length
    assert observed.any? { |row| row["last_id"] == page.id }
    assert_equal page.title, page.reload.title
  end
end
