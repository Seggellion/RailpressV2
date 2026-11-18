require "test_helper"
require Rails.root.join("lib/railpress/site_archive")
class SiteArchiveTest < ActiveSupport::TestCase
  def altered_header(bytes, offset, value)
    altered = bytes.dup
    altered[offset, value.bytesize] = value
    altered[148, 8] = " " * 8
    altered[148, 8] = "%06o\0 " % altered[0, 512].bytes.sum
    altered
  end
  test "strict tar rejects tampering truncation compression unsafe paths and duplicate JSON" do
    bytes = Railpress::SiteArchive.build({ "format"=>"synthetic", "title"=>"Tokyo" }, {})
    assert_equal "Tokyo", Railpress::SiteArchive.read(bytes)[0]["title"]
    bad = bytes.dup; bad.setbyte(600, bad.getbyte(600) ^ 1)
    [ bad, bytes[0...-600], "\x1f\x8b".b + "0" * 1024, "PK" + "0" * 1024 ].each { |input| assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.read(input) } }
    assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.parse('{"one":1,"one":2}') }
    assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.parse("\xff".b) }
    %w[../escape /absolute C:/absolute media/../escape media/x.png manifest.json/child].each { |path| assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.path!(path) } }
  end
  test "valid tar checksums cannot authorize links duplicates oversized entries or traversal" do
    bytes = Railpress::SiteArchive.build({ "format"=>"synthetic" }, {})
    [ "1", "2", "5", "x", "L" ].each do |type|
      error = assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.read(altered_header(bytes, 156, type)) }
      assert_equal "archive_type_or_permissions", error.message
    end
    [ "../outside", "/absolute", "media/../escape", "C:/outside" ].each do |path|
      assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.read(altered_header(bytes, 0, path.ljust(100, "\0"))) }
    end
    oversized = altered_header(bytes, 124, "%011o\0" % (Railpress::PortabilityContract::MAX_MANIFEST + 1))
    assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.read(oversized) }
    duplicated = bytes[0, 1024] + bytes
    error = assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.read(duplicated) }
    assert_equal "duplicate_archive_path", error.message
    deeply_nested = "[" * 41 + "0" + "]" * 41
    assert_raises(Railpress::SiteArchive::Invalid) { Railpress::SiteArchive.parse(deeply_nested) }
  end
end
