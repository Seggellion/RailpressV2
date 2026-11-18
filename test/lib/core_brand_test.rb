require "test_helper"
require "zlib"

class CoreBrandTest < ActiveSupport::TestCase
  def assert_rgba_png(bytes, size)
    assert_equal "\x89PNG\r\n\x1a\n".b, bytes.byteslice(0, 8)
    assert_equal [ size, size ], bytes.byteslice(16, 8).unpack("NN")
    assert_equal [ 8, 6 ], bytes.byteslice(24, 2).unpack("CC")
    offset = 8
    chunks = []
    while offset < bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1("N")
      type = bytes.byteslice(offset + 4, 4)
      assert_operator offset + length + 12, :<=, bytes.bytesize
      payload = bytes.byteslice(offset + 8, length)
      assert_equal Zlib.crc32(type + payload), bytes.byteslice(offset + 8 + length, 4).unpack1("N")
      chunks << type
      offset += length + 12
      break if type == "IEND"
    end
    assert_equal bytes.bytesize, offset
    assert_includes chunks, "IDAT"
    assert_equal "IEND", chunks.last
  end

  test "original raster identity has intact PNG ICO assets and inactive legacy retention" do
    manifest = JSON.parse(Rails.root.join("docs/brand/ASSET_MANIFEST.json").read)
    assert_equal "railpress.core-brand.v2", manifest.fetch("format")
    assert_equal "original-ruby-and-rails", manifest.fetch("mark_id")
    assert_equal false, manifest.fetch("authentic_vector")
    assert_equal false, manifest.fetch("wordmark_included")
    assert_equal "MIT", manifest.fetch("approval").fetch("copyright_license")
    assert_equal "Seggellion", manifest.fetch("creator")
    assert_equal "Altama Systems Incorporated", manifest.fetch("copyright_owner")
    assert_equal "reserved; no trademark grant inferred", manifest.fetch("approval").fetch("trademark_rights")
    assert_equal manifest.fetch("roles").fetch("emblem"), CoreBrandHelper::MARK
    refute_match(/\.svg\z/, CoreBrandHelper::MARK)
    (manifest.fetch("files") + manifest.fetch("legacy_retention_files")).each do |row|
      path = Rails.root.join(row.fetch("path"))
      assert path.file?
      refute path.symlink?
      assert_equal row.fetch("sha256"), Digest::SHA256.file(path).hexdigest
      assert_equal row.fetch("bytes"), path.size
    end
    pngs = manifest.fetch("files").select { |r| r["content_type"] == "image/png" }
    assert_equal [ 16, 32, 48, 180, 192, 512 ], pngs.select { |r| r["path"].start_with?("public/") }.map { |r| r.fetch("width") }.sort
    pngs.each { |row| assert_rgba_png(Rails.root.join(row.fetch("path")).binread, row.fetch("width")) }
    ico = Rails.root.join("public", CoreBrandHelper::ICO_ICON.delete_prefix("/")).binread
    assert_equal [ 0, 1, 4 ], ico.byteslice(0, 6).unpack("vvv")
    expected_offset = 70
    [ 16, 32, 48, 256 ].each_with_index do |size, index|
      entry = 6 + index * 16
      assert_equal size == 256 ? 0 : size, ico.getbyte(entry)
      assert_equal size == 256 ? 0 : size, ico.getbyte(entry + 1)
      assert_equal [ 1, 32 ], ico.byteslice(entry + 4, 4).unpack("vv")
      length, start = ico.byteslice(entry + 8, 8).unpack("VV")
      assert_equal expected_offset, start
      assert_operator start + length, :<=, ico.bytesize
      assert_rgba_png(ico.byteslice(start, length), size)
      expected_offset += length
    end
    assert_equal ico.bytesize, expected_offset
  end
end
