# Native, loopback-only Dusk production/rendering qualification.
require "bundler/setup"
require "json"
require "net/http"
require "nokogiri"
require "openssl"
require "socket"
require "timeout"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../../lib/railpress/test_database"
root = File.expand_path("../..", __dir__); Dir.chdir(root)
engine, confirmation = ARGV
abort "Usage: dusk_production_smoke.rb postgresql|mysql2 --confirm-synthetic" unless confirmation == "--confirm-synthetic"
target = Railpress::TestDatabase.load!(root: root, engine: engine, environment: "test", confirmed: "railpress-synthetic-only")
identity = Railpress::TestDatabase.verify!(target, environment: "test", confirmed: "railpress-synthetic-only")
milestone = ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE", "M07")
raise "M07 evidence only" unless %w[M07 M07/resumed].include?(milestone)
out = File.join(root, "docs/evidence", milestone)
work = Dir.mktmpdir("dusk-#{engine}-", File.join(root, ".local/state"))
persistent = Dir.mktmpdir("railpress-m07-persistent-", "/tmp")
theme_root = File.join(persistent, "themes"); media_root = File.join(persistent, "media")
[ theme_root, media_root ].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
info_path = File.join(work, "identity.json")
seed_env = { "RAILPRESS_THEME_ROOT" => theme_root, "RAILPRESS_PRIVATE_STATE_ROOT" => File.join(work, "bootstrap"), "RAILPRESS_DUSK_FIXTURE_INFO" => info_path, "RAILPRESS_EVIDENCE_MILESTONE" => milestone, "RAILPRESS_DUSK_PRODUCTION_MEDIA" => media_root }
def child!(environment, *args, log:)
  pid = Process.spawn(environment, RbConfig.ruby, *args, out: log, err: [ :child, :out ])
  _, status = Process.wait2(pid)
  raise "Fixture helper failed: #{File.basename(log)}" unless status.success?
end
control = lambda do |name|
  child!(seed_env.merge("RAILPRESS_DUSK_CONTROL" => name), File.join(root, "bin/native_test"), engine, "--confirm-synthetic", "runner", "scripts/native/dusk_fixture_control.rb", log: File.join(work, "control-#{name}.log"))
end
seeded = false; puma = nil; browser = nil
rows = []; cookies = {}; success = false
begin
  child!(seed_env, File.join(root, "bin/native_test"), engine, "--confirm-synthetic", "runner", "scripts/native/dusk_fixture_seed.rb", log: File.join(work, "seed.log"))
  seeded = true
  info = JSON.parse(File.read(info_path))
  control.call("artwork_proof")
  # Copy only the selected fixture's disk objects into explicit private production storage.
  source_media = File.join(root, ".local/state/media/test", engine)
  FileUtils.cp_r(Dir.glob(File.join(source_media, "*")), media_root)
  certificate = OpenSSL::X509::Certificate.new; key = OpenSSL::PKey::RSA.new(2048)
  certificate.version = 2; certificate.serial = SecureRandom.random_number(2**64)
  certificate.subject = OpenSSL::X509::Name.parse("/CN=localhost"); certificate.issuer = certificate.subject
  certificate.public_key = key.public_key; certificate.not_before = Time.now - 60; certificate.not_after = Time.now + 7200
  factory = OpenSSL::X509::ExtensionFactory.new; factory.subject_certificate = certificate; factory.issuer_certificate = certificate
  certificate.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
  certificate.add_extension(factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
  certificate.sign(key, OpenSSL::Digest.new("SHA256"))
  cert_path = File.join(work, "cert.pem"); key_path = File.join(work, "key.pem")
  File.write(cert_path, certificate.to_pem, perm: 0o600); File.write(key_path, key.to_pem, perm: 0o600)
  [ 59107, 59108 ].each { |port| probe = TCPServer.new("127.0.0.1", port); probe.close }
  environment = seed_env.merge("RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => nil, "SECRET_KEY_BASE" => SecureRandom.hex(64), "RAILPRESS_HTTPS_ORIGIN" => "https://localhost:59107", "RAILPRESS_STORAGE_ROOT" => media_root,
    "RAILPRESS_DB_ADAPTER" => target.fetch("adapter"), "RAILPRESS_DB_HOST" => target.fetch("host"), "RAILPRESS_DB_PORT" => target.fetch("port").to_s, "RAILPRESS_DB_NAME" => target.fetch("database"), "RAILPRESS_DB_USER" => target.fetch("username"), "RAILPRESS_DB_PASSWORD" => target.fetch("password"))
  store = OpenSSL::X509::Store.new; store.add_cert(certificate)
  request = lambda do |method, path, parameters = nil, headers = {}|
    http = Net::HTTP.new("localhost", 59107, nil); http.ipaddr = "127.0.0.1"; http.use_ssl = true
    http.cert_store = store; http.verify_mode = OpenSSL::SSL::VERIFY_PEER; http.verify_hostname = true; http.open_timeout = 2; http.read_timeout = 5
    klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post }.fetch(method)
    req = klass.new(path, headers); req["Cookie"] = cookies.values.join("; ") if cookies.any?
    if parameters
      req["Origin"] = "https://localhost:59107"; req.set_form_data(parameters)
    end
    response = http.request(req)
    Array(response.get_fields("set-cookie")).each { |cookie| pair = cookie.split(";", 2).first; cookies[pair.split("=", 2).first] = pair }
    response
  end
  observe = lambda do |name, path, family, status: 200, canonical: true, private_preview: false|
    response = request.call("GET", path)
    raise "#{name}: #{response.code}" unless response.code.to_i == status
    document = Nokogiri::HTML5(response.body)
    raise "#{name}: family" unless family.nil? || document.css("[data-dusk-family=#{family}]").one?
    raise "#{name}: h1" unless document.css("h1").one?
    raise "#{name}: private exposure" if response.body.match?(/PRIVATE DUSK CANARY|DRAFT DUSK CANARY|FUTURE DUSK CANARY|PRIVATE WORKING BODY|PRIVATE FUTURE BODY/)
    canonicals = document.css('link[rel="canonical"]').map { |node| node["href"] }
    raise "#{name}: canonical" unless canonical ? canonicals.one? && canonicals.first.start_with?("https://localhost:59107/") : canonicals.empty?
    raise "#{name}: preview leakage" if !private_preview && response.body.include?("PRIVATE DUSK OVERLAY CANARY")
    if status == 404 || private_preview
      raise "#{name}: robots" unless response["x-robots-tag"] == "noindex, nofollow"
    end
    document.css('link[rel=stylesheet],script[src],img[src]').each do |node|
      asset = request.call("GET", node["href"] || node["src"])
      raise "#{name}: missing asset" unless asset.code == "200"
    end if status == 200
    rows << { case: name, path: path, family: family, status: status, canonical: canonicals, robots: response["x-robots-tag"], stylesheet_count: document.css("link[rel=stylesheet]").length }
    response
  end
  # Fixture-only navigation injection in a native Rack launcher, never an app initializer.
  launcher = File.join(work, "launch.rb")
  File.write(launcher, "require #{File.join(root, 'config/environment').inspect}\nrequire #{File.join(root, 'scripts/themes/navigation_contract_fixture').inspect}\nThemes::Navigation.define_singleton_method(:call) { |site:| DuskNavigationContractFixture.call(site: site) }\nrequire 'puma/cli'\nPuma::CLI.new(ARGV).run\n")
  puma = Process.spawn(environment, RbConfig.ruby, launcher, "-b", "ssl://127.0.0.1:59107?key=#{key_path}&cert=#{cert_path}", out: File.join(work, "puma.log"), err: [ :child, :out ], pgroup: true)
  Timeout.timeout(25) { loop { begin; break if request.call("GET", "/up").code == "200"; rescue Errno::ECONNREFUSED, EOFError; end; raise "Puma exited" if Process.waitpid(puma, Process::WNOHANG); sleep 0.1 } }
  observe.call("static_home", "/", "front")
  %w[services about contact privacy docs long-read missing-media].each { |slug| observe.call(slug, "/#{slug}", "page") }
  observe.call("post_media", "/blog/note-1", "post")
  control.call("missing_media")
  missing = observe.call("missing_media_fallback", "/missing-media", "page")
  raise "missing image fallback" unless Nokogiri::HTML5(missing.body).at_css(".media-unavailable[role=img]")
  control.call("restore_media")
  archive = observe.call("archive", "/blog", "archive")
  raise "pagination count" unless Nokogiri::HTML5(archive.body).css(".dusk-card").length == 12
  second = observe.call("pagination", "/blog?page=2", "archive")
  raise "page two count" unless Nokogiri::HTML5(second.body).css(".dusk-card").length == 1
  observe.call("category", "/category/field-notes", "taxonomy")
  observe.call("tag", "/tag/materials", "taxonomy")
  observe.call("search", "/search?q=considered", "search")
  observe.call("empty_search", "/search?q=nonexistent", "empty")
  %w[private draft future].each { |slug| observe.call("private_#{slug}", "/blog/#{slug}", "not_found", status: 404, canonical: false) }
  observe.call("not_found", "/no/such/page", "not_found", status: 404, canonical: false)
  control.call("blog"); observe.call("blog_home", "/", "archive"); control.call("static")
  page = request.call("GET", "/login"); csrf = Nokogiri::HTML5(page.body).at_css('meta[name="csrf-token"]')["content"]
  login = request.call("POST", "/login", { "identifier" => "dusk-fixture-owner", "password" => info.fetch("password"), "authenticity_token" => csrf })
  raise "login" unless login.code == "303"
  panel = request.call("GET", "/admin/themes"); csrf = Nokogiri::HTML5(panel.body).at_css('meta[name="csrf-token"]')["content"]
  preview = request.call("POST", "/admin/themes/#{info.fetch('package_id')}/preview", { "overlay_id" => info.fetch("candidate_id"), "authenticity_token" => csrf })
  raise "preview" unless preview.code == "303"
  response = observe.call("owner_customization_preview", "/", "front", canonical: false, private_preview: true)
  raise "preview missing" unless response.body.include?("PRIVATE DUSK OVERLAY CANARY") && response.body.include?("dusk-header-centered")
  saved = cookies.dup; cookies.clear
  observe.call("anonymous_during_preview", "/", "front")
  cookies.replace(saved)
  panel = request.call("GET", "/admin/themes"); csrf = Nokogiri::HTML5(panel.body).at_css('meta[name="csrf-token"]')["content"]
  request.call("POST", "/admin/themes/stop-preview", { "authenticity_token" => csrf }); cookies.clear
  control.call("empty")
  observe.call("empty_home", "/", "home")
  observe.call("empty_archive", "/blog", "empty")
  control.call("restore")
  control.call("broken")
  response = request.call("GET", "/")
  raise "broken recovery" unless response.code == "503" && response["x-robots-tag"] == "noindex, nofollow" && !response.body.include?('rel="canonical"')
  rows << { case: "broken_component", status: 503, robots: response["x-robots-tag"] }
  raise "protected login" unless request.call("GET", "/login").code == "200"
  control.call("recover"); observe.call("recovered_default", "/", "front")
  # Actual Chrome uses the public test-mode HTTP endpoint only; no auth/TLS policy is relaxed.
  if ENV["RAILPRESS_DUSK_HOLD_CHROME"] == "1"
    browser_launcher = File.join(work, "browser.rb")
    File.write(browser_launcher, File.read(launcher))
    browser = Process.spawn(seed_env.merge("RAILS_ENV" => "test", "RAILPRESS_TEST_ENGINE" => engine, "RAILPRESS_TEST_CONFIRM" => "railpress-synthetic-only"), RbConfig.ruby, browser_launcher, "-b", "tcp://127.0.0.1:59108", out: File.join(work, "browser.log"), err: [ :child, :out ], pgroup: true)
    # Parent verified target; test database configuration independently verifies the registry.
    File.write(File.join(out, "#{engine}-chrome-ready.json"), JSON.pretty_generate({ url: "http://localhost:59108", engine: engine, mode: "test public HTTP, separate real production TLS checks", work: work }) + "\n")
    puts "CHROME_READY"; $stdout.flush
    Timeout.timeout(3600) { sleep 0.25 until File.exist?(File.join(work, "chrome-finished")) }
  end
  File.write(File.join(out, "#{engine}-dusk-production.json"), JSON.pretty_generate({ environment: "production", tls_verification: "peer and hostname against fixture CA", identity: identity, source_digest: info.fetch("digest"), observations: rows }) + "\n")
  success = true
ensure
  [ browser, puma ].compact.each do |pid|
    begin; Process.kill("TERM", -pid); Timeout.timeout(10) { Process.wait(pid) }; rescue Errno::ESRCH, Errno::ECHILD; rescue Timeout::Error; Process.kill("KILL", -pid) rescue nil; end
  end
  control.call("cleanup") if seeded
  File.write(File.join(out, "#{engine}-dusk-process-result.json"), JSON.pretty_generate({ success: success, work: work, persistent_root: persistent, processes_stopped: true, seeded: seeded, observations_before_exit: rows }) + "\n")
end
puts "Dusk real production rendering complete"
