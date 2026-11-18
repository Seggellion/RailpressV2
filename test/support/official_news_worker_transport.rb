# Test-process transport seam only. Never loaded by application configuration.
require_relative "../../config/environment"
raise "Synthetic test process only" unless Rails.env.test? && ENV["RAILPRESS_TEST_CONFIRM"]=="railpress-synthetic-only"
target=Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
Railpress::TestDatabase.verify!(target)
directory=File.realpath(ENV.fetch("RAILPRESS_NEWS_TLS_FIXTURE"))
root=Rails.root.join(".local/state/m13-native-http", ENV.fetch("RAILPRESS_TEST_ENGINE")).realpath.to_s
raise "Exact private TLS fixture required" unless directory.start_with?(root+"/") && File.stat(directory).uid==Process.uid && (File.stat(directory).mode&0o077).zero?
port=Integer(File.read(File.join(directory, "port")))
raise "High test port required" unless port.between?(1024, 65535)
uri=URI.parse("https://railpress.org:#{port}/api/public/v1/news.json")
store=OpenSSL::X509::Store.new
store.add_cert(OpenSSL::X509::Certificate.new(File.read(File.join(directory, "certificate.pem"))))
guard=Object.new
guard.define_singleton_method(:call) do |url|
  raise "Fixed provider identity required" unless url==OfficialNews::Schema::ENDPOINT
  Seo::HttpTargetGuard::Result.new(uri: uri, ip_address: "127.0.0.1")
end
original=OfficialNews::Client.method(:new)
OfficialNews::Client.define_singleton_method(:new) do |**options|
  original.call(guard: guard, cert_store: store, **options)
end
