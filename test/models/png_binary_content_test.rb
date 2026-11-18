require "test_helper"
require_relative "../support/media_test_support"

class PngBinaryContentTest < ActiveSupport::TestCase
  include MediaTestSupport

  def chunk(type, payload)
    [ payload.bytesize ].pack("N") + type + payload + [ Zlib.crc32(type + payload) ].pack("N")
  end

  def binary_png
    header = [ 2, 1, 8, 6, 0, 0, 0 ].pack("NNCCCCC")
    pixels = "\0<?\x30\xff\x40\x50\x60\xff".b
    "\x89PNG\r\n\x1a\n".b + chunk("IHDR", header) + chunk("IDAT", Zlib.deflate(pixels, Zlib::NO_COMPRESSION)) + chunk("IEND", "".b)
  end

  test "valid compressed pixels containing markup byte pairs are decoded and normalized" do
    bytes = binary_png
    assert_includes bytes, "<?"
    assert Railpress::ImageInput.png_pixels!(bytes, Railpress::ImageInput.inspect!(bytes))
    asset = upload_media(bytes: bytes)
    assert_equal "ready", asset.state
    assert_equal [ 2, 1 ], [ asset.width, asset.height ]
    assert_equal Digest::SHA256.hexdigest(bytes), asset.source_sha256
    assert_equal 2, Vips::Image.new_from_buffer(MediaLibrary::Delivery.read(asset, "display"), "").width
  end

  test "metadata markup trailers corrupt streams and CRC failures remain rejected" do
    bytes = binary_png
    [ "<?xml version='1.0'?>", "<script>x()</script>", "<svg onload='x()'/>", "javascript:alert(1)" ].each do |text|
      marked = bytes.byteslice(0, 33) + chunk("tEXt", "Comment\0#{text}".b) + bytes.byteslice(33..)
      error = assert_raises(MediaLibrary::Upload::Rejected) { upload_media(bytes: marked) }
      assert_includes error.message, "active_content"
    end
    [ bytes + "<script>x()</script>", bytes.dup.tap { |value| value.setbyte(45, value.getbyte(45) ^ 1) },
      bytes.byteslice(0, 33) + chunk("IDAT", "<?invalid-zlib".b) + chunk("IEND", "".b) ].each do |invalid|
      assert_raises(MediaLibrary::Upload::Rejected) { upload_media(bytes: invalid) }
    end
    assert_equal 0, MediaAsset.count
    assert_empty Dir.children(MediaLibrary::Storage.work_root)
  end
end
