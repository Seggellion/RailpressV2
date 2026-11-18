require "test_helper"
require_relative "../support/theme_test_support"
class ThemePackageTest < ActiveSupport::TestCase
  include ThemeTestSupport
  def verify(directory)
    Railpress::ThemePackage.load(directory, trusted_keys: @keys)
  end
  def mutation(name)
    ->(manifest, directory) do
      case name
      when "missing_template" then manifest["templates"].delete("post")
      when "incompatible_api" then manifest["theme_api"] = 999
      when "traversal" then manifest["templates"]["post"] = "../admin/index.html.erb"
      when "absolute_path" then manifest["templates"]["post"] = "/etc/passwd"
      when "unknown_manifest" then manifest["ruby_plugin"] = "plugin.rb"
      when "protected_admin" then FileUtils.mkdir_p(File.join(directory, "admin")); File.write(File.join(directory, "admin/index.html.erb"), "override")
      when "oversized_package" then Railpress::ThemeFixture.replace(manifest, directory, "templates/post.html.erb", "x" * (Railpress::ThemePackage::MAX_BYTES + 1))
      when "malformed_css" then Railpress::ThemeFixture.replace(manifest, directory, "assets/public.css", ".theme { color: red;")
      when "remote_css" then Railpress::ThemeFixture.replace(manifest, directory, "assets/public.css", "@import 'https://attacker.invalid/x';")
      when "active_asset" then manifest["assets"]["public"]["file"] = "assets/attack.js"
      when "duplicate_normalized_path" then File.write(File.join(directory, "templates/POST.html.erb"), "duplicate")
      when "symlink" then File.symlink("/etc/passwd", File.join(directory, "assets/leak.css"))
      when "malformed_png"
        content = "not a PNG"; path = "assets/logo.png"
        File.write(File.join(directory, path), content); manifest["files"][path] = Digest::SHA256.hexdigest(content)
        manifest["assets"]["logo"] = { "file" => path, "sha256" => manifest["files"][path], "byte_size" => content.bytesize, "content_type" => "image/png" }
      end
    end
  end
  %w[missing_template incompatible_api traversal absolute_path unknown_manifest protected_admin oversized_package malformed_css remote_css active_asset duplicate_normalized_path symlink malformed_png].each do |name|
    test "preflight refuses #{name} without catalog mutation" do
      directory = package_directory(mutate: mutation(name))
      assert_raises(Railpress::ThemePackage::Invalid) { Themes::Manager.stage!(actor: @owner, directory: directory) }
      assert_equal 0, ThemeInstallation.count
      assert_nil ThemeState.first&.active_installation_id
    end
  end
  test "unsigned invalid signature unknown signer checksum and duplicate JSON are refused" do
    directory = package_directory
    signature_path = File.join(directory, "signature.json")
    signature = File.read(signature_path)
    File.unlink(signature_path)
    assert_raises(Railpress::ThemePackage::Invalid) { verify(directory) }
    File.write(signature_path, signature.sub(/"signature":"[^"]+"/, '"signature":"' + Base64.strict_encode64("x" * 64) + '"'))
    assert_raises(Railpress::ThemePackage::Invalid) { verify(directory) }
    File.write(signature_path, signature)
    assert_raises(Railpress::ThemePackage::Invalid) { Railpress::ThemePackage.load(directory, trusted_keys: {}) }
    File.write(File.join(directory, "templates/post.html.erb"), "tampered")
    assert_raises(Railpress::ThemePackage::Invalid) { verify(directory) }
    assert_raises(Railpress::ThemePackage::Invalid) { Railpress::ThemePackage.parse('{"id":"a","id":"b"}') }
  end
  %w[protected_head resolver_escape runtime_error oversized_output recursive_component cpu_loop environment_secret].each do |name|
    test "production smoke refuses #{name} before activation and preserves prior" do
      prior = stage("dusk"); activate(prior)
      source = case name
      when "protected_head" then '<meta name="robots" content="index">'
      when "resolver_escape" then '<%= render file: "/etc/passwd" %>'
      when "runtime_error" then '<% raise "synthetic failure" %>'
      when "oversized_output" then '<%= "x" * 300000 %>'
      when "recursive_component" then '<%= theme_component "footer" %>'
      when "cpu_loop" then "<% loop {} %>"
      else '<% raise "credential leak" if ENV.key?("RAILPRESS_DB_PASSWORD") %><% raise "production required" unless ENV["RAILS_ENV"] == "production" %><% raise "bounded cpu required" unless Process.getrlimit(:CPU)[0] == 6 %><% raise "intentional smoke refusal after environment proof" %>'
      end
      family = name == "recursive_component" ? "footer" : "post"
      directory = package_directory(mutate: ->(manifest, dir) { Railpress::ThemeFixture.replace(manifest, dir, "templates/#{family}.html.erb", source) })
      assert_raises(Railpress::ThemePackage::Invalid) { Themes::Manager.stage!(actor: @owner, directory: directory) }
      assert_equal prior.id, ThemeState.first.active_installation_id
      assert_equal 1, ThemeInstallation.count
    end
  end
  test "verified immutable bundle and exact canonical digest validate both original references" do
    %w[dusk harbor].each do |id|
      bundle = verify(package_directory(id))
      assert bundle.manifest.frozen?
      assert bundle.manifest["templates"].frozen?
      assert bundle.files.values.all?(&:frozen?)
      assert_equal 13, bundle.manifest["templates"].size
      assert_equal Digest::SHA256.hexdigest(Railpress::ThemePackage.canonical(bundle.manifest)), bundle.digest
      assert_equal id, bundle.manifest["id"]
    end
  end
  test "production smoke proves scrubbed credentials and all family renders" do
    previous = ENV["RAILPRESS_DB_PASSWORD"]; ENV["RAILPRESS_DB_PASSWORD"] = "synthetic-not-for-child"
    candidate = stage(mutate: ->(manifest, dir) do
      Railpress::ThemeFixture.replace(manifest, dir, "templates/post.html.erb", '<% raise "leak" if ENV.key?("RAILPRESS_DB_PASSWORD") %><% raise "mode" unless ENV["RAILS_ENV"] == "production" %><% raise "limit" unless Process.getrlimit(:CPU)[0] == 6 %><p>Bounded production</p>')
    end)
    assert_equal "production", candidate.smoke_report["environment"]
    assert_equal "none", candidate.smoke_report["database"]
    assert_equal Railpress::ThemePackage::FAMILIES, candidate.smoke_report["families"]
  ensure
    ENV["RAILPRESS_DB_PASSWORD"] = previous
  end
  test "published native harness accepts original signed bundle and refuses tampering" do
    require "open3"
    directory = package_directory
    keys = File.join(Themes::Storage.root, "trusted-keys.json")
    output, errors, status = Open3.capture3(RbConfig.ruby, Rails.root.join("bin/railpress-theme-check").to_s, directory, keys)
    assert status.success?, errors
    result = JSON.parse(output)
    assert_equal "PASS", result["result"]
    assert_equal "production", result["environment"]
    assert_equal 13, result["families"].length
    File.write(File.join(directory, "templates/post.html.erb"), "tamper")
    _output, errors, status = Open3.capture3(RbConfig.ruby, Rails.root.join("bin/railpress-theme-check").to_s, directory, keys)
    refute status.success?
    assert_includes errors, "file_checksum"
  end
  test "PNG package asset validates structural pixels and actual bounded production decode" do
    source = image_bytes(width: 32, height: 32)
    add_image = ->(manifest, directory, bytes) do
      path = "assets/logo.png"
      File.binwrite(File.join(directory, path), bytes)
      sha = Digest::SHA256.hexdigest(bytes)
      manifest["files"][path] = sha
      manifest["assets"]["logo"] = { "file" => path, "sha256" => sha, "byte_size" => bytes.bytesize, "content_type" => "image/png" }
    end
    package = stage(mutate: ->(manifest, directory) { add_image.call(manifest, directory, source) })
    assert_equal "image/png", package.manifest.dig("assets", "logo", "content_type")
    bad = source.dup
    offset = 8
    loop do
      size = bad.byteslice(offset, 4).unpack1("N")
      if bad.byteslice(offset + 4, 4) == "IDAT"
        payload = "x" * size
        bad[offset + 8, size] = payload
        bad[offset + 8 + size, 4] = [ Zlib.crc32("IDAT" + payload) ].pack("N")
        break
      end
      offset += size + 12
    end
    directory = package_directory(version: "1.1.0", mutate: ->(manifest, dir) { add_image.call(manifest, dir, bad) })
    assert_raises(Railpress::ThemePackage::Invalid) { Themes::Manager.stage!(actor: @owner, directory: directory) }
    assert_equal 1, ThemeInstallation.count
  end
end
