require "test_helper"
require_relative "../support/media_test_support"
require_relative "../support/native_host_test_support"

class NativeRestoreIntegrityTest < ActiveSupport::TestCase
  include MediaTestSupport
  include NativeHostTestSupport
  setup { native_setup }
  teardown { native_teardown }

  def prepare_point
    @asset = upload_media(actor: @owner)
    @page = draft("Page", actor: @owner, title: "Recovery 日本語", slug: "recovery-integrity",
      blocks: [ { "type" => "image", "media_id" => @asset.id } ], featured_media_id: @asset.id)
    change(@page, "publish", actor: @owner)
    @preview, = Editorial::Previews.issue!(actor: @owner, content: @page)
    @member = Member.create!(site: Site.first, public_id: SecureRandom.uuid)
    @old_session = UserSession.issue!(@owner)
    @disk = ActiveStorage::Service::DiskService.new(root: @native_config.path("shared/media"))
    @media = [ @asset.blob, @asset.thumbnail_blob ].to_h do |blob|
      bytes = blob.download
      @disk.upload(blob.key, StringIO.new(bytes), checksum: blob.checksum)
      [ blob.key, Digest::SHA256.hexdigest(bytes) ]
    end
    @metadata = snapshot_create
    @operation = SecureRandom.uuid
    @point_dump = @native_config.path("snapshots", @metadata["snapshot_id"], "database.dump")
  end
  def native_count(table) = @native_db.query("SELECT COUNT(*) AS n FROM #{@native_db.quote_identifier(table)}").first.fetch("n").to_i
  # Legacy destructive replay is unsupported. Catalog/record comparison remains
  # independently tested without leaving the shared test database damaged.
  def evidence = @metadata.dig("site_report", "database_integrity")
  def changed_evidence
    expected = Marshal.load(Marshal.dump(evidence))
    yield expected
    expected["schema_sha256"] = Digest::SHA256.hexdigest(Railpress::Releases.canonical(expected["schema"]))
    expected
  end
  test "signed snapshot records relationships and actual media verify without replay" do
    prepare_point
    assert @native_db.integrity.verify!(evidence)
    assert_equal 1, native_count("members")
    assert_equal @member.public_id, @native_db.query("SELECT public_id FROM members").first.fetch("public_id")
    assert_equal @page.published_snapshot, @page.reload.published_snapshot
    @media.each { |key, checksum| assert_equal checksum, Digest::SHA256.hexdigest(@disk.download(key)) }
    assert UserSession.resolve(@old_session)
    refute_empty evidence.fetch("after_revocation")
  end
  test "missing table and foreign key evidence cannot match a complete real catalog" do
    prepare_point
    %w[tables foreign_keys].each do |key|
      expected = changed_evidence { |row| row.fetch("schema").fetch(key).pop }
      error = assert_raises(Railpress::NativeHost::DatabaseIntegrity::SchemaMismatch) { @native_db.integrity.verify!(expected) }
      assert_equal "restored_database_schema_integrity", error.message
    end
    assert @native_db.integrity.verify!(evidence)
  end
  test "member count and microsecond row hashes are compared without scalar truncation" do
    prepare_point
    expected = changed_evidence { |row| row.fetch("before").fetch("members")["count"] = 0 }
    assert_raises(Railpress::NativeHost::Error) { @native_db.integrity.verify!(expected) }
    rows = [ { "created_at" => "2026-11-16 01:02:03.000001" } ]
    refute_equal @native_db.integrity.records(rows), @native_db.integrity.records([ { "created_at" => "2026-11-16 01:02:03.000002" } ])
    assert @native_db.integrity.verify!(evidence)
  end
  test "orphan data stops test cleanup even with complete schema and enabled checks" do
    prepare_point
    connection = ActiveRecord::Base.connection
    if ENV.fetch("RAILPRESS_TEST_ENGINE") == "mysql2"
      connection.transaction(requires_new: true) do
        connection.execute("SET SESSION foreign_key_checks=0")
        connection.execute("UPDATE media_assets SET author_id=999999999")
        connection.execute("SET SESSION foreign_key_checks=1")
        error = assert_raises(TestSchemaIntegrity::Unsafe) { TestSchemaIntegrity.verify! }
        assert_match(/orphan data/, error.message)
        raise ActiveRecord::Rollback
      ensure
        connection.execute("SET SESSION foreign_key_checks=1")
      end
    else
      assert_raises(PG::ForeignKeyViolation) { @native_db.execute("UPDATE media_assets SET author_id=999999999") }
    end
    assert TestSchemaIntegrity.verify!
    assert @native_db.integrity.verify!(evidence)
  end
  test "legacy snapshot evidence remains mandatory independently of unsupported replay" do
    prepare_point
    @metadata["site_report"].delete("database_integrity")
    Railpress::NativeHost::F.atomic(@native_config.path("snapshots", @metadata["snapshot_id"], "snapshot.json"),
      Railpress::Releases.canonical(Railpress::NativeHost.sign(@metadata, @native_signer)))
    error = assert_raises(Railpress::NativeHost::Error) { snapshot_validate(@metadata["snapshot_id"]) }
    assert_equal "snapshot_database_evidence_missing", error.message
    assert_empty Dir.glob(@native_config.path("logs", "restore-*"))
  end

  test "equivalent PostgreSQL literal array casts normalize without erasing value changes" do
    integrity = @native_db.integrity
    first = "CHECK (role::text = ANY (ARRAY['owner'::character varying, 'editor'::character varying]::text[]))"
    second = "CHECK (role::text = ANY (ARRAY['owner'::character varying::text, 'editor'::character varying::text]))"
    assert_equal integrity.normalize_check(first), integrity.normalize_check(second)
    refute_equal integrity.normalize_check(first), integrity.normalize_check(second.sub("editor", "intruder"))
    limited = "CHECK (role = ANY (ARRAY['owner'::character varying(2)]::text[]))"
    assert_equal limited, integrity.normalize_check(limited)
  end

  test "a weaker check cannot pass normalized real schema verification" do
    prepare_point
    expected = changed_evidence do |row|
      check = row.fetch("schema").fetch("checks").find { |item| item.values.include?("users_valid_role") }
      assert check
      key = ENV.fetch("RAILPRESS_TEST_ENGINE") == "postgresql" ? "definition" : "CHECK_CLAUSE"
      previous = check.fetch(key)
      check[key] = previous.sub(/\)\z/, " OR true)")
      refute_equal previous, check[key]
    end
    error = assert_raises(Railpress::NativeHost::DatabaseIntegrity::SchemaMismatch) { @native_db.integrity.verify!(expected) }
    assert_equal "restored_database_schema_integrity", error.message
    assert @native_db.integrity.verify!(evidence)
  end
end
