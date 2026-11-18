require "test_helper"
require "timeout"
require "active_storage/service/railpress_gcs_service"
require_relative "../support/media_test_support"
require_relative "../support/gcs_test_support"

class GcsStorageTest < ActiveSupport::TestCase
  include GcsTestSupport
  test "cold production GCS upload loads its dependencies without a prior Disk boot" do
    target = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
    child_env = { "RAILS_ENV" => "production", "DISABLE_BOOTSNAP" => "1", "SECRET_KEY_BASE" => SecureRandom.hex(64),
      "RAILPRESS_COLD_ROOT" => Rails.root.to_s, "RAILPRESS_PRIVATE_STATE_ROOT" => @private_root,
      "RAILPRESS_STORAGE_BACKEND" => "gcs", "RAILPRESS_GCS_PROJECT" => "synthetic-project", "RAILPRESS_GCS_BUCKET" => "synthetic-bucket",
      "RAILPRESS_GCS_PREFIX" => "r8/cold", "RAILPRESS_QUARANTINE_ROOT" => File.join(@private_root, "cold-processing"),
      "GOOGLE_APPLICATION_CREDENTIALS" => nil, "RAILPRESS_GCS_CREDENTIALS_FILE" => nil,
      "GOOGLE_PRIVATE_KEY" => nil, "GOOGLE_CLIENT_SECRET" => nil, "GOOGLE_REFRESH_TOKEN" => nil }
    { "ADAPTER" => "adapter", "HOST" => "host", "PORT" => "port", "NAME" => "database", "USER" => "username", "PASSWORD" => "password" }.each do |suffix, key|
      child_env["RAILPRESS_DB_#{suffix}"] = target.fetch(key).to_s
    end
    script = <<~'RUBY'
      require ENV.fetch("RAILPRESS_COLD_ROOT") + "/config/environment"
      require Rails.root.join("test/support/gcs_api_fixture").to_s
      api = GcsApiFixture.new
      service = ActiveStorage::Blob.service
      raise "GCS must be the cold default" unless service.is_a?(ActiveStorage::Service::RailpressGcsService)
      service.instance_variable_set(:@store, Railpress::Gcs::Store.new(bucket: "synthetic-bucket", project: "synthetic-project", prefix: "r8/cold", client: api))
      Google::Auth.define_singleton_method(:get_application_default) { |*| raise "no actual ADC allowed" }
      Google::Cloud::Storage.define_singleton_method(:new) { |*| raise "no actual provider allowed" }
      bytes = Vips::Image.black(32, 24).new_from_image([20, 70, 90]).pngsave_buffer
      asset = MediaLibrary::Upload.call(actor: User.find_by!(role: "owner"), io: StringIO.new(bytes), filename: "cold.png", content_type: "image/png", attributes: { "alt_text" => "Synthetic cold GCS image" })
      raise "ready private immutable objects" unless asset.state == "ready" && api.objects.length == 2 && asset.blob.metadata.fetch("railpress_gcs")["prefix"] == "r8/cold"
      raise "integrity" unless Digest::SHA256.hexdigest(MediaLibrary::Delivery.read(asset, "display")) == asset.sha256
      puts "COLD_GCS_PRODUCTION: ready=true objects=2 checksum=true actual_provider_calls=0"
    RUBY
    log = Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE", "qualification"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-cold-gcs-production.log")
    FileUtils.mkdir_p(log.dirname)
    pid = Process.spawn(child_env, RbConfig.ruby, "-e", script, chdir: Rails.root.to_s, out: log.to_s, err: [ :child, :out ], pgroup: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
    loop do
      waited, status = Process.waitpid2(pid, Process::WNOHANG)
      if waited
        pid = nil
        assert status.success?, File.read(log)
        assert_includes File.read(log), "COLD_GCS_PRODUCTION: ready=true"
        break
      end
      flunk "Cold production GCS deadline; retained #{log.basename}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
  ensure
    if pid
      Process.kill("TERM", -pid) rescue Errno::ESRCH
      begin
        Timeout.timeout(8) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end
  end
  def prefixed_service
    @service.instance_variable_set(:@store, Railpress::Gcs::Store.new(bucket: "synthetic-bucket", project: "synthetic-project", prefix: "r8/media", client: @api))
  end
  test "optional prefix binds physical namespace generation checksum and recovery manifest" do
    require Rails.root.join("lib/railpress/recovery")
    prefixed_service
    asset = upload_media
    binding = asset.blob.metadata.fetch("railpress_gcs")
    assert_match(/\A[0-9a-f]{64}\z/, binding["key"])
    assert_equal "r8/media", binding["prefix"]
    assert @api.objects.key?("r8/media/" + binding["key"])
    refute @api.objects.key?(binding["key"])
    assert_equal "VERIFIED", @service.store.verify(binding)
    Railpress::Recovery::Manifest.validate_object!(binding)
    assert_equal "MISMATCH", @service.store.verify(binding.except("prefix"))
    assert_equal "MISMATCH", @service.store.verify(binding.merge("prefix" => "unrelated"))
    wrong = Railpress::Gcs::Store.new(bucket: "synthetic-bucket", project: "synthetic-project", prefix: "unrelated", client: @api)
    assert_equal "MISSING", wrong.verify(binding)
    before = @api.fingerprint
    MediaLibrary::Manage.purge!(actor: @author, asset: asset)
    assert_equal before, @api.fingerprint
    assert_equal "r8/media", asset.reload.retained_objects.first["prefix"]
    assert_equal "VERIFIED", @service.store.verify(asset.retained_objects.first)
  end
  test "prefixed missing inaccessible and wrong generations fail without unrelated substitution" do
    prefixed_service
    asset = upload_media
    binding = asset.blob.metadata.fetch("railpress_gcs")
    physical = "r8/media/" + asset.blob.key
    @api.objects[asset.blob.key] = @api.objects.delete(physical)
    assert_nil MediaLibrary::Delivery.read(asset, "display")
    assert_equal "MISSING", @service.store.verify(binding)
    @api.objects[physical] = @api.objects.delete(asset.blob.key)
    @api.objects[physical][0].generation = "999999"
    assert_nil MediaLibrary::Delivery.read(asset, "display")
    @api.failure = Google::Cloud::PermissionDeniedError.new("PRIVATE-CANARY")
    assert_equal "INACCESSIBLE", @service.store.verify(binding)
    assert_empty @api.calls.select { |row| %w[delete restore policy].include?(row[0]) }
  end
  test "validated upload records actual SDK generation canonical SHA and private create-only intent" do
    asset = upload_media
    assert_equal 2, @api.objects.length
    binding = asset.blob.metadata.fetch("railpress_gcs")
    assert_equal asset.sha256, binding["sha256"]
    assert_match(/\A[1-9][0-9]+\z/, binding["generation"])
    assert_equal asset.byte_size, binding["byte_size"]
    assert_same @service, asset.blob.service
    assert_equal asset.sha256, Digest::SHA256.hexdigest(asset.blob.download)
    assert_equal asset.sha256, Digest::SHA256.hexdigest(MediaLibrary::Delivery.read(asset, "display"))
    @api.calls.select { |row| row[0] == "insert" }.each do |row|
      assert_equal 0, row[3][:if_generation_match]
      assert_nil row[3][:acl]
      assert_equal "private, no-store", row[3][:cache_control]
    end
    assert @api.calls.any? { |row| row[0] == "download" && row[3][:generation].to_s == binding["generation"] }
    assert_raises(Railpress::Gcs::Failure) { @service.url(asset.blob.key) }
    assert_raises(Railpress::Gcs::Failure) { @service.url_for_direct_upload(asset.blob.key) }
  end
  test "overwrite precondition refuses without altering stored content" do
    asset = upload_media
    before = @api.fingerprint
    error = assert_raises(Railpress::Gcs::Failure) { @service.upload(asset.blob.key, StringIO.new("different")) }
    assert_equal "MISMATCH", error.status
    assert_equal before, @api.fingerprint
  end
  test "logical purge and rejected upload retain object identities for older backups" do
    asset = upload_media
    before = @api.fingerprint
    binding = asset.blob.metadata.fetch("railpress_gcs").dup
    MediaLibrary::Manage.purge!(actor: @author, asset: asset)
    assert_equal "purged", asset.reload.state
    assert_nil asset.blob_id
    assert_equal binding, asset.retained_objects.first
    assert_equal 2, asset.retained_objects.length
    assert_nil MediaLibrary::Delivery.read(asset, "display")
    assert_equal before, @api.fingerprint
    assert_equal "VERIFIED", @service.store.verify(binding)
    assert_raises(Railpress::Gcs::Failure) { @service.delete(binding["key"]) }
    assert_raises(MediaLibrary::Upload::Rejected) { upload_media(alt_text: "") }
    assert_equal 4, @api.objects.length
    assert_equal 2, MediaUpload.last.storage_keys.length
    MediaUpload.last.update!(updated_at: 2.hours.ago)
    CleanupMediaUploadsJob.perform_now
    assert_equal 2, MediaUpload.last.storage_keys.length
    assert_equal 4, @api.objects.length
  end
  test "missing noncurrent wrong generation checksum permission and outage never deliver bytes" do
    asset = upload_media
    key = asset.blob.key
    saved = @api.objects.delete(key)
    assert_nil MediaLibrary::Delivery.read(asset, "display")
    assert_equal "MISSING", @service.store.verify(asset.blob.metadata["railpress_gcs"])
    @api.objects[key] = saved
    saved[0].generation = "9999"
    assert_nil MediaLibrary::Delivery.read(asset, "display")
    saved[0].generation = asset.blob.metadata["railpress_gcs"]["generation"]
    forged = asset.blob.metadata["railpress_gcs"].merge("sha256" => "0" * 64)
    assert_equal "MISMATCH", @service.store.verify(forged)
    @api.failure = Google::Cloud::PermissionDeniedError.new("secret-token-must-not-escape")
    assert_nil MediaLibrary::Delivery.read(asset, "display")
    assert_equal "INACCESSIBLE", @service.store.verify(forged)
    error = assert_raises(Railpress::Gcs::Failure) { @service.store.read(key) }
    refute_includes error.full_message, "secret-token"
    @api.failure = IOError.new("secret-provider-outage")
    assert_equal "UNKNOWN", @service.store.verify(forged)
    assert_equal %w[UNKNOWN], @service.store.policy_status.values.uniq
    assert_empty @api.calls.select { |row| %w[delete restore policy].include?(row[0]) }
  end
  test "lazy service boot requires no credentials or provider and bounded objects reject abuse" do
    service = ActiveStorage::Service::RailpressGcsService.new(bucket: "unconfigured-bucket", project: "unconfigured-project")
    assert_nil service.store.instance_variable_get(:@client)
    refute service.public?
    assert_raises(Railpress::Gcs::Failure) { @service.upload("../escape", StringIO.new("x")) }
    assert_raises(Railpress::Gcs::Failure) { @service.upload("a" * 64, StringIO.new("x" * (Railpress::Gcs::MAX_BYTES + 1))) }
    assert_empty @api.objects
    @api.private_access = false
    error = assert_raises(Railpress::Gcs::Failure) { @service.upload("b" * 64, StringIO.new("test")) }
    assert_equal "UNSUPPORTED", error.status
    assert_empty @api.objects
  end
end
