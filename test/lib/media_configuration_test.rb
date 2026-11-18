require "test_helper"
require "tmpdir"
require "google/cloud/storage"

class MediaConfigurationTest < ActiveSupport::TestCase
  C = Railpress::MediaConfiguration
  def fields
    { "backend" => "gcs", "project" => "synthetic-project", "bucket" => "synthetic-private-media", "prefix" => "media/images", "auth_method" => "adc", "identity_source" => "federation" }
  end
  def replacing(receiver, name, implementation)
    original = receiver.method(name)
    receiver.define_singleton_method(name, implementation)
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end
  def credential(type = "external_account")
    Dir.mktmpdir("railpress-r8-credentials-", "/dev/shm") do |dir|
      path = File.join(dir, "identity.json")
      File.write(path, JSON.generate({ "type" => type, "credential_source" => { "file" => "/synthetic-subject-token-not-opened" } }), mode: "wx", perm: 0o600)
      env("HOME" => dir) { yield path }
    end
  end
  def env(values)
    before = values.to_h { |k, _| [ k, ENV[k] ] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    before.each { |k, v| ENV[k] = v }
  end
  test "typed settings contain only nonsecret canonical fields and reject endpoint shaped input" do
    chosen = C.selection(fields)
    assert_equal 1, chosen["version"]
    assert_equal fields, chosen.except("version")
    assert_equal 64, C.fingerprint(chosen).size
    assert_raises(C::Invalid) { C.validate!(chosen.merge("credentials" => "MUST-NOT-PERSIST")) }
    [ "https://host.invalid/", "169.254.169.254", "ab", "goog-test", "has..dots", "name/other", "a" * 64 ].each do |name|
      assert_raises(C::Invalid) { C.selection(fields.merge("bucket" => name)) }
    end
    [ "x", "UPPER-project", "https://bad.invalid", "a" * 31 ].each { |name| assert_raises(C::Invalid) { C.selection(fields.merge("project" => name)) } }
    [ "../other", "/root", "last/", "a//b", "a%2fb", "x" * 129 ].each { |prefix| assert_raises(C::Invalid) { C.selection(fields.merge("prefix" => prefix)) } }
    assert_raises(C::Invalid) { C.selection(fields.merge("auth_method" => "automatic-fallback")) }
    assert_raises(C::Invalid) { C.selection(fields.merge("identity_source" => "https://metadata.invalid")) }
  end
  test "disk needs no Google configuration and discards inactive GCS values" do
    value = C.selection(fields.merge("backend" => "local"), disk_root: "/synthetic/private/media")
    assert_equal({ "version" => 1, "backend" => "local", "disk_root" => "/synthetic/private/media" }, value)
    assert_equal value, C.validate!(value)
    assert_raises(C::Invalid) { C.selection({ "backend" => "local" }, disk_root: "../public") }
  end
  test "local federation and development inspection never discovers credentials or contacts metadata" do
    replacing(Google::Auth, :get_application_default, ->(*) { flunk "local configuration inspection must not discover ADC" }) do
      credential do |path|
        assert_equal "CONFIGURED", C.credential_status(C.selection(fields), env: { "GOOGLE_APPLICATION_CREDENTIALS" => path })["state"]
        File.chmod(0o644, path)
        assert_equal "ACTION REQUIRED", C.credential_status(C.selection(fields), env: { "GOOGLE_APPLICATION_CREDENTIALS" => path })["state"]
      end
      credential("authorized_user") do |path|
        assert_equal "ACTION REQUIRED", C.credential_status(C.selection(fields), env: { "GOOGLE_APPLICATION_CREDENTIALS" => path })["state"]
        result = C.credential_status(C.selection(fields.merge("identity_source" => "development")), env: { "GOOGLE_APPLICATION_CREDENTIALS" => path })
        assert_equal "CONFIGURED", result["state"]
        assert_includes result["detail"], "not production"
      end
      Dir.mktmpdir("railpress-r8-empty-home-", "/dev/shm") do |home|
        assert_equal "ACTION REQUIRED", C.credential_status(C.selection(fields), env: {}, home: home)["state"]
        attached = C.selection(fields.merge("identity_source" => "attached"))
        result = C.credential_status(attached, env: {}, home: home)
        assert_equal "CONFIGURED", result["state"]
        assert_includes result["detail"], "NOT TESTED"
      end
    end
  end
  test "fallback must be explicit private and service account typed with no inline serialization" do
    credential("service_account") do |path|
      selected = C.selection(fields.merge("auth_method" => "service_account_file"))
      assert_equal "native", selected["identity_source"]
      assert_equal "CONFIGURED", C.credential_status(selected, env: { "RAILPRESS_GCS_CREDENTIALS_FILE" => path })["state"]
      adc = C.selection(fields)
      assert_equal "ACTION REQUIRED", C.credential_status(adc, env: { "RAILPRESS_GCS_CREDENTIALS_FILE" => path })["state"]
      assert_equal "ACTION REQUIRED", C.credential_status(adc, env: { "GOOGLE_APPLICATION_CREDENTIALS" => path })["state"]
      refute_includes JSON.generate(selected), path
    end
  end
  test "credential files reject symlinks malformed data executable federation and source repository paths" do
    credential do |path|
      link = path + ".link"
      File.symlink(path, link)
      assert_raises(C::Invalid) { C.credential_document!(link) }
      File.write(path, '{"type":"external_account","credential_source":{"executable":{"command":"never-run"}}}')
      assert_raises(C::Invalid) { C.credential_document!(path) }
      File.write(path, "broken JSON SECRET-CANARY")
      error = assert_raises(C::Invalid) { C.credential_document!(path) }
      refute_includes error.full_message, "SECRET-CANARY"
    end
    assert_raises(C::Invalid) { C.credential_document!(Rails.root.join("Gemfile").to_s) }
  end
  test "runtime ADC uses maintained discovery object and never Storage-specific key aliases" do
    credential do |path|
      identity = Object.new
      seen = nil
      env("GOOGLE_APPLICATION_CREDENTIALS" => path, "STORAGE_CREDENTIALS" => "ignored-private-alias") do
        replacing(Google::Auth, :get_application_default, ->(scopes) { seen = scopes; identity }) do
          result = C.credentials(method: "adc", identity_source: "federation")
          assert_same identity, result
          assert_equal [ "https://www.googleapis.com/auth/devstorage.read_write" ], seen
          client_options = nil
          fake_client = Object.new
          replacing(Google::Cloud::Storage, :new, ->(**options) { client_options = options; fake_client }) do
            store = Railpress::Gcs::Store.new(bucket: "synthetic-bucket", project: "synthetic-project", identity_source: "federation")
            assert_same fake_client, store.client
            assert_same identity, client_options[:credentials]
            assert_equal 0, client_options[:retries]
            assert_equal [ 10, 3, 5, 5 ], client_options.values_at(:timeout, :open_timeout, :read_timeout, :send_timeout)
          end
        end
      end
    end
  end
  test "missing selected federation and bad ADC never silently invoke service account fallback" do
    Dir.mktmpdir("railpress-r8-empty-home-", "/dev/shm") do |home|
      env("GOOGLE_APPLICATION_CREDENTIALS" => nil, "CLOUDSDK_CONFIG" => home, "HOME" => home) do
        replacing(Google::Auth, :get_application_default, ->(*) { flunk "federation missing; must stop before discovery" }) do
          assert_raises(C::Invalid) { C.credentials(method: "adc", identity_source: "federation") }
        end
      end
    end
    credential do |path|
      env("GOOGLE_APPLICATION_CREDENTIALS" => path) do
        replacing(Google::Auth, :get_application_default, ->(*) { raise C::Invalid, "selected ADC unavailable" }) do
          replacing(Google::Auth::ServiceAccountCredentials, :make_creds, ->(**) { flunk "no key fallback" }) do
            assert_raises(C::Invalid) { C.credentials(method: "adc") }
          end
        end
      end
    end
  end
  test "explicit fallback delegates only to the selected maintained service account factory" do
    test_case = self
    credential("service_account") do |path|
      identity = Object.new
      replacing(Google::Auth, :get_application_default, ->(*) { flunk "fallback must not discover another identity" }) do
        replacing(Google::Auth::ServiceAccountCredentials, :make_creds, ->(json_key_io:, scope:) {
          test_case.assert_equal "service_account", JSON.parse(json_key_io.read)["type"]
          test_case.assert_equal [ "https://www.googleapis.com/auth/devstorage.read_write" ], scope
          identity
        }) do
          assert_same identity, C.credentials(method: "service_account_file", file: path)
        end
      end
    end
  end
  test "inline Google keys cannot silently become the ADC source" do
    config = C.selection(fields.merge("identity_source" => "attached"))
    assert_equal "ACTION REQUIRED", C.credential_status(config, env: { "GOOGLE_PRIVATE_KEY" => "SYNTHETIC-NOT-A-KEY" })["state"]
    env("GOOGLE_PRIVATE_KEY" => "SYNTHETIC-NOT-A-KEY") do
      replacing(Google::Auth, :get_application_default, ->(*) { flunk "inline key must stop before discovery" }) do
        assert_raises(C::Invalid) { C.credentials(method: "adc") }
      end
    end
  end
end
