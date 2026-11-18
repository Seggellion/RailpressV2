require "test_helper"
require_relative "../support/media_test_support"

class MediaSafetyTest < ActiveSupport::TestCase
  include MediaTestSupport
  test "PNG and JPEG are decoded and stored as private canonical PNG with true dimensions" do
    [ [ ".png", "image/png", "studio.png" ], [ ".jpg", "image/jpeg", "studio.jpg" ] ].each do |format, type, filename|
      bytes = image_bytes(format)
      asset = upload_media(bytes: bytes, type: type, filename: filename)
      assert_equal "ready", asset.state
      assert_equal "image/png", asset.content_type
      assert_equal [ 80, 40 ], [ asset.width, asset.height ]
      assert_equal Digest::SHA256.hexdigest(bytes), asset.source_sha256
      stored = MediaLibrary::Delivery.read(asset, "display")
      assert stored.start_with?("\x89PNG".b)
      assert_equal asset.sha256, Digest::SHA256.hexdigest(stored)
      assert_equal "accepted", MediaUpload.order(:id).last.state
      assert_empty Dir.children(MediaLibrary::Storage.work_root)
    end
  end
  test "real native transformations bound display and thumbnail dimensions" do
    asset = upload_media(bytes: image_bytes(width: 2000, height: 1000))
    assert_equal [ 1600, 800 ], [ asset.width, asset.height ]
    thumb = Vips::Image.new_from_buffer(MediaLibrary::Delivery.read(asset, "thumb"), "")
    assert_equal [ 400, 200 ], [ thumb.width, thumb.height ]
  end
  test "maximum accepted PNG pixels normalize repeatedly within the native child bounds" do
    bytes = image_bytes(width: 4000, height: 4000)
    assert_operator bytes.bytesize, :<, Railpress::ImageInput::MAX_BYTES
    3.times do
      asset = upload_media(bytes: bytes)
      assert_equal "ready", asset.state
      assert_equal [ 4000, 4000 ], [ asset.source_width, asset.source_height ]
      assert_equal [ 1600, 1600 ], [ asset.width, asset.height ]
      assert_equal "accepted", MediaUpload.order(:id).last.state
      assert_empty Dir.children(MediaLibrary::Storage.work_root)
    end
  end
  test "active formats type mismatch trailers CRC errors and pixel bombs are rejected" do
    payloads = [ "<svg onload='x()'/>".b, "<html><script>x()</script>".b, "GIF89a".b,
      image_bytes + "<script>x()</script>", image_bytes + "PK\x03\x04", image_bytes.dup.tap { |x|x.setbyte(29, x.getbyte(29)^1) } ]
    payloads.each { |bytes| assert_raises(MediaLibrary::Upload::Rejected) { upload_media(bytes: bytes) } }
    assert_raises(MediaLibrary::Upload::Rejected) { upload_media(type: "text/html") }
    huge = image_bytes.dup
    huge[16, 8] = [ 9000, 9000 ].pack("NN")
    huge[29, 4] = [ Zlib.crc32(huge.byteslice(12, 17)) ].pack("N")
    assert_raises(MediaLibrary::Upload::Rejected) { upload_media(bytes: huge) }
    assert_equal 0, MediaAsset.count
    assert_empty Dir.children(MediaLibrary::Storage.work_root)
  end
  test "media ownership metadata and purge authorization use current authority" do
    asset = upload_media
    assert_raises(Identity::Capabilities::Denied) { MediaLibrary::Manage.update!(actor: @editor.tap { |u|Identity::ManageUsers.change_role!(actor: @owner, user: u, role: "author") }, asset: asset, attributes: { "alt_text"=>"stolen" }, version: asset.lock_version) }
    MediaLibrary::Manage.update!(actor: @author, asset: asset, attributes: { "caption"=>"<script>plain text</script>", "author_id"=>@owner.id }, version: asset.lock_version)
    assert_equal @author.id, asset.reload.author_id
    assert_equal "<script>plain text</script>", asset.caption
    MediaLibrary::Manage.purge!(actor: @author, asset: asset)
    assert_equal "purged", asset.reload.state
    assert_nil asset.blob_id
  end
end
