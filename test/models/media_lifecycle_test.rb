require "test_helper"
require "open3"
require_relative "../support/media_test_support"
class MediaLifecycleTest < ActiveSupport::TestCase
  include MediaTestSupport
  def in_work
    dir=Dir.mktmpdir("check-", MediaLibrary::Storage.work_root)
    yield dir
  ensure
    MediaLibrary::Storage.remove_work!(dir) if dir && File.directory?(dir)
  end
  test "oversize streaming input rejects before decoder and deletes quarantine" do
    with_method(MediaLibrary::Processor, :worker_path, -> { flunk "Oversize input reached decoder" }) do
      assert_raises(MediaLibrary::Upload::Rejected) { upload_media(bytes: "x"*(Railpress::ImageInput::MAX_BYTES+1)) }
    end
    assert_empty Dir.children(MediaLibrary::Storage.work_root)
    assert_equal "rejected", MediaUpload.last.state
  end
  test "metadata failure leaves no object records or quarantined bytes" do
    before=ActiveStorage::Blob.count
    assert_raises(MediaLibrary::Upload::Rejected) { upload_media(alt_text: "") }
    assert_equal before, ActiveStorage::Blob.count
    assert_equal "rejected", MediaUpload.last.state
    assert_equal [], MediaUpload.last.storage_keys
    assert_empty Dir.children(MediaLibrary::Storage.work_root)
  end
  test "decoder wall timeout kills and reaps only its native child" do
    in_work do |dir|
      input=File.join(dir, "input");File.binwrite(input, image_bytes)
      worker=File.join(dir, "sleep.rb")
      File.write(worker, 'File.write(File.join(ARGV[1],"pid"),Process.pid.to_s); sleep 30')
      started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      with_method(MediaLibrary::Processor, :worker_path, -> { worker }) do
        error=assert_raises(MediaLibrary::Processor::Failed) { MediaLibrary::Processor.run!(input, dir) }
        assert_equal "timeout", error.message
      end
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC)-started, :<, 9
      pid=File.read(File.join(dir, "pid")).to_i
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end
  test "native child receives bounded resources and no parent credential environment" do
    previous=ENV["RAILPRESS_DB_PASSWORD"];ENV["RAILPRESS_DB_PASSWORD"]="synthetic-child-environment-canary"
    in_work do |dir|
      input=File.join(dir, "input");File.binwrite(input, image_bytes)
      worker=File.join(dir, "limits.rb")
      File.write(worker, <<~RUBY)
        require "json"
        File.binwrite(File.join(ARGV[1],"display.png"),"bounded")
        File.binwrite(File.join(ARGV[1],"thumb.png"),"bounded")
        File.write(File.join(ARGV[1],"info.json"),JSON.generate(secret_present:ENV.key?("RAILPRESS_DB_PASSWORD"),arenas:ENV["MALLOC_ARENA_MAX"],cpu:Process.getrlimit(:CPU)[0],memory:Process.getrlimit(:AS)[0],output:Process.getrlimit(:FSIZE)[0]))
      RUBY
      result=with_method(MediaLibrary::Processor, :worker_path, -> { worker }) { MediaLibrary::Processor.run!(input, dir) }
      refute result["secret_present"]
      assert_equal 4, result["cpu"]
      assert_equal "2", result["arenas"]
      assert_equal 768*1024*1024, result["memory"]
      assert_equal MediaLibrary::Processor::OUTPUT_BYTES, result["output"]
    end
  ensure
    ENV["RAILPRESS_DB_PASSWORD"]=previous
  end
  test "normalization removes original metadata and image containers reject animation" do
    bytes=image_bytes
    text="Comment\0private-camera-location".b
    chunk=[ text.bytesize ].pack("N")+"tEXt"+text+[ Zlib.crc32("tEXt"+text) ].pack("N")
    marked=bytes.byteslice(0, 33)+chunk+bytes.byteslice(33..)
    asset=upload_media(bytes: marked)
    refute_includes MediaLibrary::Delivery.read(asset, "display"), "private-camera-location"
    animation=[ 8 ].pack("N")+"acTL"+[ 2, 0 ].pack("NN")
    animation << [ Zlib.crc32(animation.byteslice(4..)) ].pack("N")
    assert_raises(MediaLibrary::Upload::Rejected) { upload_media(bytes: bytes.byteslice(0, 33)+animation+bytes.byteslice(33..)) }
  end
  test "purge is retryable after interruption between physical objects" do
    asset=upload_media
    original=MediaLibrary::Storage.method(:delete_key!)
    with_method(MediaLibrary::Storage, :delete_key!, ->(key) { original.call(key);raise IOError, "synthetic interruption" }) do
      assert_raises(IOError) { MediaLibrary::Manage.purge!(actor: @author, asset: asset) }
    end
    assert_equal "purging", asset.reload.state
    assert asset.blob_id
    MediaLibrary::Manage.purge!(actor: @author, asset: asset)
    assert_equal "purged", asset.reload.state
    assert_nil asset.blob_id
    MediaLibrary::Manage.purge!(actor: @author, asset: asset)
    assert_equal "purged", asset.state
  end
  test "abandoned object journals clean up safely and accepted uploads are retained" do
    asset=upload_media
    key=SecureRandom.hex(32)
    ActiveStorage::Blob.service.upload(key, StringIO.new("synthetic abandoned object"))
    stale=MediaUpload.create!(author: @author, state: "processing", storage_keys: [ key ], updated_at: 2.hours.ago)
    CleanupMediaUploadsJob.perform_now
    assert_equal "rejected", stale.reload.state
    refute ActiveStorage::Blob.service.exist?(key)
    assert MediaLibrary::Delivery.read(asset, "display")
  end
  test "persistent native disk survives separate release-root processes and rollback" do
    asset=upload_media
    in_work do |dir|
      %w[r1 r2].each { |name|FileUtils.mkdir_p(File.join(dir, name)) }
      script=File.join(dir, "read.rb")
      File.write(script, <<~RUBY)
        require "bundler/setup"
        require "active_support/all"
        require "active_storage"
        require "active_storage/service"
        require "active_storage/service/disk_service"
        require "digest"
        service=ActiveStorage::Service::DiskService.new(root:ARGV[0])
        puts Digest::SHA256.hexdigest(service.download(ARGV[1]))
      RUBY
      link=File.join(dir, "current")
      %w[r1 r2 r1].each do |release|
        File.unlink(link) if File.symlink?(link)
        File.symlink(File.join(dir, release), link)
        output, error, status=Open3.capture3(RbConfig.ruby, script, ActiveStorage::Blob.service.root.to_s, asset.blob.key, chdir: link)
        assert status.success?, error
        assert_equal asset.sha256, output.strip
      end
      puts "STORAGE_RELEASE_OBSERVATION: adapter=#{ENV.fetch('RAILPRESS_TEST_ENGINE')} roots=r1,r2,r1 retained_sha256=#{asset.sha256}"
    end
  end

  test "compressed scanline abuse is rejected inside the bounded native decoder" do
    original=image_bytes
    payload=Zlib.deflate("\0"*(2*1024*1024))
    chunk=[ payload.bytesize ].pack("N")+"IDAT"+payload+[ Zlib.crc32("IDAT"+payload) ].pack("N")
    bomb=original.byteslice(0, 33)+chunk+original.byteslice(-12, 12)
    assert_raises(MediaLibrary::Upload::Rejected) { upload_media(bytes: bomb) }
    assert_equal 0, MediaAsset.count
    assert_empty Dir.children(MediaLibrary::Storage.work_root)
  end
  test "production storage refuses implicit relative release-local or non-private roots" do
    previous=ENV["RAILPRESS_STORAGE_ROOT"]
    with_method(Rails, :env, -> { ActiveSupport::StringInquirer.new("production") }) do
      ENV.delete("RAILPRESS_STORAGE_ROOT")
      assert_raises(MediaLibrary::Storage::Unsafe) { MediaLibrary::Storage.ensure_private! }
      ENV["RAILPRESS_STORAGE_ROOT"]="../shared"
      assert_raises(MediaLibrary::Storage::Unsafe) { MediaLibrary::Storage.ensure_private! }
      ENV["RAILPRESS_STORAGE_ROOT"]=ActiveStorage::Blob.service.root.to_s
      assert_raises(MediaLibrary::Storage::Unsafe) { MediaLibrary::Storage.ensure_private! }
    end
  ensure
    ENV["RAILPRESS_STORAGE_ROOT"]=previous
  end
end
