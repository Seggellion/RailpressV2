# frozen_string_literal: true

require "test_helper"
require_relative "../support/theme_upload_test_support"

class ThemeArchiveTest < ActiveSupport::TestCase
  ARCHIVE = Railpress::ThemeArchive

  test "stored and streamed deflate entries agree with their directory and account for metadata" do
    files = { "manifest.json" => '{"synthetic":true}', "templates/home.html.erb" => "<p>Synthetic</p>" }
    [ false, true ].each do |method|
      Dir.mktmpdir("native-theme-archive-") do |root|
        path = ThemeZipFixture.write(File.join(root, "transport.zip"), files, compress: method, descriptor: method, comment: "metadataPK\x05\x06")
        extracted = File.join(root, "verified")
        Dir.mkdir(extracted, 0o700)
        File.open(path, "rb") { |input| ARCHIVE::Reader.new(input).extract!(extracted) }
        files.each { |name, bytes| assert_equal bytes, File.binread(File.join(extracted, name)) }
      end
    end
  end

  test "invalid archive names types headers checksums count and ratios fail closed" do
    valid = [ [ "manifest.json", "{}" ] ]
    assert_rejected("zip_path", [ [ "templates/../manifest.json", "{}" ] ])
    assert_rejected("zip_path", [ [ "/manifest.json", "{}" ] ])
    assert_rejected("zip_path", [ [ "assets/payload.zip", "{}" ] ])
    assert_rejected("zip_duplicate_name", valid + valid)
    assert_rejected("zip_unnecessary_directory", [ [ "assets/", "" ], *valid ])
    assert_rejected("zip_file_size", [ [ "signature.json", "a" * 2049 ] ])
    assert_rejected("zip_directory", valid * 49)
    assert_rejected("zip_ratio", [ [ "assets/public.css", "x" * 50_000 ] ], compress: true)
    assert_rejected("zip_end_record", valid) { |bytes| bytes.byteslice(0, bytes.bytesize - 1) }
    assert_rejected("zip_checksum", valid) do |bytes|
      bytes.setbyte(30 + "manifest.json".bytesize, "x".ord)
      bytes
    end
    assert_rejected("zip_file_type", valid) do |bytes|
      central = bytes.index("PK\x01\x02".b)
      bytes[central + 38, 4] = [ 0o120777 << 16 ].pack("V")
      bytes
    end
  end

  test "multipart guard bounds actual data even with absent or incorrect length" do
    reached = []
    endpoint = ->(env) { reached << env.fetch("rack.input").read; [ 201, {}, [] ] }
    guard = Railpress::ThemeUploadLimit.new(endpoint)
    path = { "PATH_INFO" => "/admin/themes/uploads", "REQUEST_METHOD" => "POST" }
    limit = Railpress::ThemeUploadLimit::MAX_BYTES
    [ nil, "1", limit.to_s ].each do |length|
      input = StringIO.new("a" * (limit + 1))
      assert_equal 413, guard.call(path.merge("CONTENT_LENGTH" => length, "rack.input" => input)).first
    end
    assert_equal 400, guard.call(path.merge("CONTENT_LENGTH" => "8", "rack.input" => StringIO.new("abc"))).first
    assert_empty reached
    assert_equal 201, guard.call(path.merge("rack.input" => StringIO.new("abc"))).first
    assert_equal [ "abc" ], reached
  end

  test "multipart guard covers the path variants accepted by the Rails upload route" do
    guard = Railpress::ThemeUploadLimit.new(->(_env) { [ 201, {}, [] ] })
    %w[/admin/themes/uploads/ /admin//themes/uploads /admin/themes/uploads.zip].each do |path|
      assert_equal "upload", Rails.application.routes.recognize_path(path, method: :post)[:action]
      env = { "PATH_INFO" => path, "REQUEST_METHOD" => "POST",
        "CONTENT_LENGTH" => (Railpress::ThemeUploadLimit::MAX_BYTES + 1).to_s, "rack.input" => StringIO.new }
      assert_equal 413, guard.call(env).first, path
    end
    refute_equal 413, guard.call("PATH_INFO" => "/admin/themes/uploads/1/resume", "REQUEST_METHOD" => "POST").first
  end

  private

  def assert_rejected(code, files, compress: false)
    Dir.mktmpdir("rejected-theme-archive-") do |root|
      path = ThemeZipFixture.write(File.join(root, "transport.zip"), files, compress: compress)
      File.binwrite(path, yield(File.binread(path))) if block_given?
      extracted = File.join(root, "verified")
      Dir.mkdir(extracted, 0o700)
      error = assert_raises(Railpress::ThemePackage::Invalid) do
        File.open(path, "rb") { |input| ARCHIVE::Reader.new(input).extract!(extracted) }
      end
      assert_equal code, error.message
    end
  end
end
