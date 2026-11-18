require "tmpdir"
require "openssl"
require "timeout"
module OfficialNewsTlsSupport
  def tls_fixture(mode)
    root=Rails.root.join(".local/state/m13-native-http", ENV.fetch("RAILPRESS_TEST_ENGINE"))
    FileUtils.mkdir_p(root, mode: 0o700)
    directory=Dir.mktmpdir("tls-", root)
    key=OpenSSL::PKey::RSA.new(2048)
    cert=OpenSSL::X509::Certificate.new
    cert.version=2;cert.serial=SecureRandom.random_number(2**64)
    cert.subject=OpenSSL::X509::Name.parse("/CN=railpress.org")
    cert.issuer=cert.subject;cert.public_key=key.public_key
    cert.not_before=Time.now-60;cert.not_after=Time.now+300
    factory=OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate=cert;factory.issuer_certificate=cert
    cert.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(factory.create_extension("subjectAltName", "DNS:railpress.org"))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    File.write(File.join(directory, "key.pem"), key.to_pem, perm: 0o600)
    File.write(File.join(directory, "certificate.pem"), cert.to_pem, perm: 0o600)
    File.write(File.join(directory, "payload.json"), JSON.generate(news_payload), perm: 0o600)
    pid=Process.spawn(RbConfig.ruby, Rails.root.join("test/support/official_news_tls_fixture.rb").to_s, directory, mode,
      out: File.join(directory, "fixture.log"), err: [ :child, :out ], pgroup: true)
    Timeout.timeout(5) { sleep 0.02 until File.exist?(File.join(directory, "port")) }
    uri=URI.parse("https://railpress.org:#{Integer(File.read(File.join(directory, "port")))}/api/public/v1/news.json")
    store=OpenSSL::X509::Store.new;store.add_cert(cert)
    # Transport-only fixture seam: production guard still rejects loopback/high ports.
    guard=Object.new
    guard.define_singleton_method(:call) do |url|
      raise "Only fixed provider requested" unless url==OfficialNews::Schema::ENDPOINT
      Seo::HttpTargetGuard::Result.new(uri: uri, ip_address: "127.0.0.1")
    end
    yield guard, store, directory, uri
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
end
