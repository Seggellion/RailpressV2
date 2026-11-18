# frozen_string_literal: true

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
root=File.expand_path("../..", __dir__)
Dir.chdir(root)
engine, confirmation=ARGV
abort "Usage: seo_production_smoke.rb postgresql|mysql2 --confirm-synthetic" unless confirmation=="--confirm-synthetic"
target=Railpress::TestDatabase.load!(root: root, engine: engine, environment: "test", confirmed: "railpress-synthetic-only")
identity=Railpress::TestDatabase.verify!(target, environment: "test", confirmed: "railpress-synthetic-only")
base=File.join(root, ".local/state/m05-production", engine)
FileUtils.mkdir_p(base, mode: 0o700)
work=Dir.mktmpdir("fixture-", base)
info=File.join(work, "identity.json")
private_root=File.join(work, "bootstrap")
seed_env={ "RAILPRESS_PRIVATE_STATE_ROOT"=>private_root, "RAILPRESS_SEO_FIXTURE_INFO"=>info }
def child!(environment, *args, log:)
  pid=Process.spawn(environment, RbConfig.ruby, *args, out: log, err: [ :child, :out ])
  _, status=Process.wait2(pid)
  raise "Fixture helper failed; inspect private log" unless status.success?
end
seeded=false
child!(seed_env, File.join(root, "bin/native_test"), engine, "--confirm-synthetic", "runner", "scripts/native/seo_fixture_seed.rb", log: File.join(work, "seed.log"))
seeded=true
certificate=OpenSSL::X509::Certificate.new
key=OpenSSL::PKey::RSA.new(2048)
certificate.version=2;certificate.serial=SecureRandom.random_number(2**64)
certificate.subject=OpenSSL::X509::Name.parse("/CN=localhost")
certificate.issuer=certificate.subject;certificate.public_key=key.public_key
certificate.not_before=Time.now-60;certificate.not_after=Time.now+1800
factory=OpenSSL::X509::ExtensionFactory.new
factory.subject_certificate=certificate;factory.issuer_certificate=certificate
certificate.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
certificate.add_extension(factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
certificate.sign(key, OpenSSL::Digest.new("SHA256"))
cert_path=File.join(work, "certificate.pem");key_path=File.join(work, "key.pem")
File.write(cert_path, certificate.to_pem, perm: 0o600);File.write(key_path, key.to_pem, perm: 0o600)
%w[58105 58106].each { |port|probe=TCPServer.new("127.0.0.1", port.to_i);probe.close }
environment=seed_env.merge("RAILS_ENV"=>"production", "SECRET_KEY_BASE_DUMMY"=>"1", "RAILPRESS_HTTPS_ORIGIN"=>"https://localhost:58105",
  "RAILPRESS_DB_ADAPTER"=>target.fetch("adapter"), "RAILPRESS_DB_HOST"=>target.fetch("host"), "RAILPRESS_DB_PORT"=>target.fetch("port").to_s,
  "RAILPRESS_DB_NAME"=>target.fetch("database"), "RAILPRESS_DB_USER"=>target.fetch("username"), "RAILPRESS_DB_PASSWORD"=>target.fetch("password"),
  "RAILPRESS_SEO_INDEXING"=>nil, "RAILPRESS_SEO_HTTP_ENABLED"=>nil)
cookies={}
rows=[]
store=OpenSSL::X509::Store.new;store.add_cert(certificate)
request=->(method, path, params = nil, headers = {}) do
  http=Net::HTTP.new("localhost", 58105, nil)
  http.ipaddr="127.0.0.1";http.use_ssl=true;http.cert_store=store;http.verify_mode=OpenSSL::SSL::VERIFY_PEER;http.verify_hostname=true
  http.open_timeout=2;http.read_timeout=5
  klass={ "GET"=>Net::HTTP::Get, "POST"=>Net::HTTP::Post, "PATCH"=>Net::HTTP::Patch, "DELETE"=>Net::HTTP::Delete }.fetch(method)
  req=klass.new(path, headers)
  req["Cookie"]=cookies.values.join("; ") if cookies.any?
  if params
    req["Origin"]="https://localhost:58105"
    req.set_form_data(params)
  end
  response=http.request(req)
  Array(response.get_fields("set-cookie")).each { |cookie|pair=cookie.split(";", 2).first;cookies[pair.split("=", 2).first]=pair }
  response
end
observe=->(name, response, canonical: nil, index: nil, status: 200, schema: nil) do
  raise "#{name}: unexpected status #{response.code}" unless response.code.to_i==status
  document=Nokogiri::HTML(response.body)
  canonical_nodes=document.css('link[rel="canonical"]')
  if canonical
    raise "#{name}: canonical mismatch" unless canonical_nodes.length==1 && canonical_nodes.first["href"]==canonical
  else
    raise "#{name}: unexpected canonical" unless canonical_nodes.empty?
  end
  if index!=nil
    expected=index ? "index, follow" : "noindex, nofollow"
    raise "#{name}: robots mismatch" unless document.css('meta[name="robots"]').length==1 && document.at_css('meta[name="robots"]')["content"]==expected && response["x-robots-tag"]==expected
  end
  types=document.css('script[type="application/ld+json"]').flat_map { |node|JSON.parse(node.text).fetch("@graph").map { |entry|entry["@type"] } }
  raise "#{name}: schema mismatch" if schema && !types.include?(schema)
  raise "#{name}: hidden text exposed" if response.body.match?(/PRIVATE DRAFT CANARY|PRIVATE DRAFT BODY|FUTURE CANARY|FUTURE BODY/)
  rows<<{ case: name, status: response.code.to_i, canonical: canonical_nodes.map { |node|node["href"] }, robots: document.css('meta[name="robots"]').map { |node|node["content"] }, schema: types }
end
success=false
begin
  puma=Process.spawn(environment, RbConfig.ruby, "-S", "bundle", "exec", "puma", "-b", "ssl://127.0.0.1:58105?key=#{key_path}&cert=#{cert_path}", "-b", "tcp://127.0.0.1:58106", out: File.join(work, "puma.log"), err: [ :child, :out ], pgroup: true)
  Timeout.timeout(25) do
    loop do
      begin
        break if request.call("GET", "/up").code=="200"
      rescue Errno::ECONNREFUSED, EOFError, Net::ReadTimeout
      end
      raise "Fixture Puma exited" if Process.waitpid(puma, Process::WNOHANG)
      sleep 0.1
    end
  end
  origin="https://localhost:58105"
  observe.call("home", request.call("GET", "/"), canonical: origin+"/", index: true, schema: "WebPage")
  observe.call("page", request.call("GET", "/about"), canonical: origin+"/about", index: true, schema: "Organization")
  observe.call("post_host_attack", request.call("GET", "/blog/news", nil, { "Host"=>"attacker.invalid", "X-Forwarded-Host"=>"evil.invalid" }), canonical: origin+"/blog/news", index: true, schema: "BlogPosting")
  forwarded=request.call("GET", "/blog/news", nil, { "Host"=>"attacker.invalid", "Forwarded"=>"host=evil.invalid;proto=http" })
  raise "Forwarded transport reflected host" unless forwarded.code=="301" && forwarded["location"]==origin+"/blog/news"
  rows<<{ case: "forwarded_proto_attack", status: 301, location: forwarded["location"] }
  %w[secret future private].each { |slug|observe.call(slug, request.call("GET", "/blog/#{slug}"), index: false, status: 404) }
  observe.call("archive", request.call("GET", "/blog"), canonical: origin+"/blog", index: true)
  observe.call("taxonomy", request.call("GET", "/category/announcements"), canonical: origin+"/category/announcements", index: true)
  observe.call("search", request.call("GET", "/search?q=Fixture"), canonical: origin+"/search?q=Fixture", index: false)
  observe.call("query_variant", request.call("GET", "/blog/news?utm=anything"), canonical: origin+"/blog/news", index: false)
  observe.call("out_of_range", request.call("GET", "/blog?page=2"), index: false, status: 404)
  observe.call("unknown", request.call("GET", "/unknown/nested"), index: false, status: 404)
  robots=request.call("GET", "/robots.txt")
  raise "Enabled robots policy mismatch" unless robots.code=="200" && robots.body.include?("Sitemap: "+origin+"/sitemap.xml") && !robots.body.include?("Disallow: /search")
  xml=request.call("GET", "/sitemap.xml")
  urls=Nokogiri::XML(xml.body).xpath("//*[local-name()='loc']").map(&:text)
  raise "Bad production inventory" unless urls.sort==%w[/ /about /blog /blog/news /category/announcements].map { |path|origin+path }.sort
  raise "ETag did not revalidate" unless request.call("GET", "/sitemap.xml", nil, { "If-None-Match"=>xml["etag"] }).code=="304"
  http=Net::HTTP.new("127.0.0.1", 58106, nil)
  redirect=http.get("/blog/news", { "Host"=>"attacker.invalid:1234", "X-Forwarded-Host"=>"evil.invalid" })
  raise "HTTPS host reflection" unless redirect.code=="301" && redirect["location"]==origin+"/blog/news"
  spoof=http.get("/blog/news", { "Host"=>"localhost:58106", "X-Forwarded-Proto"=>"https" })
  raise "Proxy spoof accepted" unless spoof.code=="426"
  token=->(response) { Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')["content"] }
  login=request.call("GET", "/login")
  signed=request.call("POST", "/login", { "identifier"=>"seo-fixture-owner", "password"=>"synthetic-seo-owner-2026!", "authenticity_token"=>token.call(login) })
  raise "Fixture login failed" unless signed.code=="303"
  raise "Cookie security lost" unless signed.get_fields("set-cookie").all? { |cookie|cookie.downcase.include?("secure") && cookie.downcase.include?("httponly") }
  panel=request.call("GET", "/admin/seo")
  observe.call("owner_panel", panel, index: false)
  raise "Unknown search engine status missing" unless panel.body.include?("Google indexing, ranking and crawling are unknown")
  queued=request.call("POST", "/admin/seo/execute", { "authenticity_token"=>token.call(panel), "mode"=>"offline" })
  raise "Diagnostic enqueue failed" unless queued.code=="303"
  worker=Process.spawn(environment, RbConfig.ruby, "bin/jobs", "--mode", "async", "--skip-recurring", out: File.join(work, "worker.log"), err: [ :child, :out ], pgroup: true)
  Timeout.timeout(30) do
    loop do
      break if request.call("GET", "/admin/seo").body.match?(/Run \d+: completed/)
      sleep 0.1
    end
  end
  item=JSON.parse(File.read(info)).fetch("post_id")
  edit=->(action, attributes = {}) do
    page=request.call("GET", "/admin/contents/#{item}/edit")
    document=Nokogiri::HTML(page.body)
    values={ "authenticity_token"=>token.call(page), "version"=>document.at_css('input[name="version"]')["value"], "editorial_action"=>action }.merge(attributes)
    response=request.call("PATCH", "/admin/contents/#{item}", values)
    raise "Editorial production action failed" unless response.code=="303"
  end
  edit.call("unpublish")
  observe.call("unpublished", request.call("GET", "/blog/news"), index: false, status: 404)
  raise "Stale sitemap after withdrawal" if request.call("GET", "/sitemap.xml").body.include?(origin+"/blog/news")
  edit.call("save", { "content[slug]"=>"renamed" })
  edit.call("publish")
  renamed=request.call("GET", "/blog/news")
  raise "Rename did not resolve identity" unless renamed.code=="301" && renamed["location"]=="/blog/renamed"
  observe.call("renamed", request.call("GET", "/blog/renamed"), canonical: origin+"/blog/renamed", index: true, schema: "BlogPosting")
  edit.call("trash")
  observe.call("trashed", request.call("GET", "/blog/renamed"), index: false, status: 404)
  settings=request.call("GET", "/admin/settings")
  disabled=request.call("PATCH", "/admin/settings", { "authenticity_token"=>token.call(settings), "site[indexing_enabled]"=>"0" })
  raise "Disable indexing failed" unless disabled.code=="303"
  observe.call("global_noindex", request.call("GET", "/about"), canonical: origin+"/about", index: false)
  raise "Disabled sitemap not empty" unless Nokogiri::XML(request.call("GET", "/sitemap.xml").body).xpath("//*[local-name()='loc']").empty?
  raise "Disabled robots policy mismatch" unless request.call("GET", "/robots.txt").body.include?("Disallow: /")
  logout=request.call("DELETE", "/logout", { "authenticity_token"=>token.call(request.call("GET", "/admin")) })
  raise "Logout failed" unless logout.code=="303"
  report={ environment: "production", scope: "verified synthetic native fixture only", engine: engine, target: identity, tls_peer_verified: true, https_redirect_fixed_origin: true, untrusted_proxy_refused: true, secure_cookie: true, production_worker_completed: true, inventory_urls: urls, rows: rows }
  File.write("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{engine}-production-render.json", JSON.pretty_generate(report)+"\n")
  success=true
  puts "#{engine}: production-mode native TLS/SEO/worker/lifecycle proof passed; #{rows.length} observations"
ensure
  [ worker, puma ].compact.each do |pid|
    Process.kill("TERM", -pid) rescue Errno::ESRCH
    begin
      Timeout.timeout(8) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("KILL", -pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    rescue Errno::ECHILD
    end
  end
  child!(seed_env.merge("RAILPRESS_SEO_FIXTURE_ABORT" => success ? "0" : "1"), File.join(root, "bin/native_test"), engine, "--confirm-synthetic", "runner", "scripts/native/seo_fixture_cleanup.rb", log: File.join(work, "cleanup.log")) if seeded
end
