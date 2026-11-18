# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "rbconfig"
require "socket"
require "timeout"
require "openssl"
require "securerandom"
require "fileutils"

root = File.expand_path("../..", __dir__)
Dir.chdir(root)
tls = File.join(root, ".local/state/synthetic-tls")
FileUtils.mkdir_p(tls, mode: 0o700)
key = OpenSSL::PKey::RSA.new(2048)
certificate = OpenSSL::X509::Certificate.new
certificate.version = 2
certificate.serial = SecureRandom.random_number(2**64)
certificate.subject = OpenSSL::X509::Name.parse("/CN=localhost")
certificate.issuer = certificate.subject
certificate.public_key = key.public_key
certificate.not_before = Time.now - 60
certificate.not_after = Time.now + 3600
factory = OpenSSL::X509::ExtensionFactory.new
factory.subject_certificate = certificate
factory.issuer_certificate = certificate
certificate.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
certificate.add_extension(factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
certificate.sign(key, OpenSSL::Digest.new("SHA256"))
key_path = File.join(tls, "key.pem")
cert_path = File.join(tls, "certificate.pem")
File.open(key_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(key.to_pem) }
File.open(cert_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(certificate.to_pem) }
def tls_client(certificate)
  client = Net::HTTP.new("127.0.0.1", 58101, nil)
  client.use_ssl = true
  client.verify_mode = OpenSSL::SSL::VERIFY_PEER
  client.cert_store = OpenSSL::X509::Store.new
  client.cert_store.add_cert(certificate)
  client
end
manifest = JSON.parse(File.read("public/assets/.manifest.json"))
asset = manifest.fetch("tailwind.css").fetch("digested_path")
expected = Digest::SHA256.file(File.join("public/assets", asset)).hexdigest
2.times do |iteration|
  socket = TCPServer.new("127.0.0.1", 58101)
  socket.close
  log = File.join(root, ".local/state/production-smoke-#{iteration}.log")
  pid = Process.spawn(
    { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1" },
    RbConfig.ruby, "-S", "bundle", "exec", "puma", "-b", "ssl://127.0.0.1:58101?key=#{key_path}&cert=#{cert_path}",
    "--pidfile", File.join(root, ".local/state/production-smoke-#{iteration}.pid"),
    out: log, err: [ :child, :out ], pgroup: true
  )
  begin
    response = nil
    readiness_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    readiness_attempts = 0
    Timeout.timeout(25) do
      loop do
        begin
          readiness_attempts += 1
          http = tls_client(certificate)
          http.open_timeout = 0.5
          http.read_timeout = 1
          response = http.get("/up")
          break if response.code == "200"
        rescue Errno::ECONNREFUSED, EOFError, Net::ReadTimeout, Net::OpenTimeout => error
          warn JSON.generate(readiness_retry: error.class.name, attempt: readiness_attempts, elapsed: Process.clock_gettime(Process::CLOCK_MONOTONIC) - readiness_started, total_limit_seconds: 25, connect_limit_seconds: 0.5, read_limit_seconds: 1)
          # Candidate is still starting; only this explicit loopback port is probed.
        end
        raise "Puma exited; inspect #{log}" if Process.waitpid(pid, Process::WNOHANG)
        sleep 0.1
      end
    end
    setup_response = tls_client(certificate).get("/setup")
    raise "uninstalled setup unavailable without DB" unless setup_response.code == "200" && setup_response.body.include?("Setup secret")
    %w[/login /admin /password/recovery].each do |path|
      gated = tls_client(certificate).get(path)
      raise "uninstalled route leaked: #{path}" unless gated.code == "303" && gated["location"].end_with?("/setup")
    end
    asset_response = tls_client(certificate).get("/assets/#{asset}")
    raise "asset unavailable" unless asset_response.code == "200"
    raise "asset bytes changed" unless Digest::SHA256.hexdigest(asset_response.body) == expected
    puts JSON.generate(iteration: iteration + 1, health: response.code, tls_peer_verified: true, uninstalled_setup: setup_response.code, gated_routes: 3, asset_status: asset_response.code, asset_sha256: expected, process_id: pid, environment: "local production-mode synthetic smoke")
  ensure
    Process.kill("TERM", -pid) rescue Errno::ESRCH
    begin
      Timeout.timeout(8) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("KILL", -pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    rescue Errno::ECHILD
      nil
    end
  end
end
