require "test_helper"
require "tmpdir"
require "fileutils"
require "openssl"
require "timeout"
class SeoNativeHttpTest < ActiveSupport::TestCase
  def fixture(mode)
    root=Rails.root.join(".local/state/m05-native-http", ENV.fetch("RAILPRESS_TEST_ENGINE"))
    FileUtils.mkdir_p(root, mode: 0o700)
    directory=Dir.mktmpdir("tls-", root)
    key=OpenSSL::PKey::RSA.new(2048)
    cert=OpenSSL::X509::Certificate.new
    cert.version=2;cert.serial=SecureRandom.random_number(2**64)
    cert.subject=OpenSSL::X509::Name.parse("/CN=fixture.example.invalid")
    cert.issuer=cert.subject;cert.public_key=key.public_key
    cert.not_before=Time.now-60;cert.not_after=Time.now+300
    factory=OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate=cert;factory.issuer_certificate=cert
    cert.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(factory.create_extension("subjectAltName", "DNS:fixture.example.invalid"))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    File.write(File.join(directory, "key.pem"), key.to_pem, perm: 0o600)
    File.write(File.join(directory, "certificate.pem"), cert.to_pem, perm: 0o600)
    pid=Process.spawn(RbConfig.ruby, Rails.root.join("test/support/seo_tls_fixture.rb").to_s, directory, mode, out: File.join(directory, "worker.log"), err: [ :child, :out ], pgroup: true)
    Timeout.timeout(5) { sleep 0.02 until File.exist?(File.join(directory, "port")) }
    port=Integer(File.read(File.join(directory, "port")))
    store=OpenSSL::X509::Store.new;store.add_cert(cert)
    yield URI.parse("https://fixture.example.invalid:#{port}/safe"), store, directory
  ensure
    if pid
      Process.kill("TERM", -pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
    if directory
      raise "Unsafe TLS fixture cleanup" unless File.realpath(directory).start_with?(root.realpath.to_s+"/")
      FileUtils.remove_entry_secure(directory)
    end
  end
  test "native TLS pins IP preserves hostname verifies peer and ignores environment proxies" do
    previous=ENV["https_proxy"];ENV["https_proxy"]="http://127.0.0.1:1"
    fixture("ok") do |uri, store, directory|
      response=Seo::NetHttpClient.new(cert_store: store).get(uri: uri, ip_address: "127.0.0.1")
      assert_equal 200, response.status
      assert_includes response.body, "native TLS"
      request=File.read(File.join(directory, "request"))
      assert_includes request, "Host: fixture.example.invalid:#{uri.port}"
      assert_includes request, "Accept-Encoding: identity"
      refute_match(/Cookie:|Authorization:/i, request)
    end
  ensure
    ENV["https_proxy"]=previous
  end
  test "native TLS refuses untrusted certificates and hostname mismatch" do
    fixture("ok") do |uri, _store, _|
      assert_raises(Seo::NetHttpClient::NetworkError) { Seo::NetHttpClient.new.get(uri: uri, ip_address: "127.0.0.1") }
    end
    fixture("ok") do |uri, store, _|
      uri.host="wrong.example.invalid"
      assert_raises(Seo::NetHttpClient::NetworkError) { Seo::NetHttpClient.new(cert_store: store).get(uri: uri, ip_address: "127.0.0.1") }
    end
  end
  test "native oversized encoded and slow responses hit actual byte and time controls" do
    %w[oversize encoded headers].each do |mode|
      fixture(mode) do |uri, store, _|
        assert_raises(Seo::NetHttpClient::ResponseTooLarge) { Seo::NetHttpClient.new(cert_store: store, response_byte_limit: 100).get(uri: uri, ip_address: "127.0.0.1") }
      end
    end
    fixture("slow") do |uri, store, _|
      started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Seo::NetHttpClient::TimeoutError) { Seo::NetHttpClient.new(cert_store: store, read_timeout: 0.2, total_timeout: 0.5).get(uri: uri, ip_address: "127.0.0.1") }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC)-started, :<, 2
    end
  end
end
