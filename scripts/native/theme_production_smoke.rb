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
abort "Usage: theme_production_smoke.rb postgresql|mysql2 --confirm-synthetic" unless confirmation=="--confirm-synthetic"
target=Railpress::TestDatabase.load!(root: root, engine: engine, environment: "test", confirmed: "railpress-synthetic-only")
identity=Railpress::TestDatabase.verify!(target, environment: "test", confirmed: "railpress-synthetic-only")
base=File.join(root, ".local/state/m06-theme-production", engine)
FileUtils.mkdir_p(base, mode: 0o700)
work=Dir.mktmpdir("fixture-", base)
release_root=Dir.mktmpdir("railpress-m06-release-", "/tmp")
theme_root=Dir.mktmpdir("railpress-m06-theme-", "/tmp")
File.chmod(0o700, theme_root)
info=File.join(work, "identity.json")
private_root=File.join(work, "bootstrap")
seed_env={ "RAILPRESS_THEME_ROOT"=>theme_root, "RAILPRESS_EVIDENCE_MILESTONE"=>ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE", "M06"), "RAILPRESS_PRIVATE_STATE_ROOT"=>private_root, "RAILPRESS_SEO_FIXTURE_INFO"=>info }
def child!(environment, *args, log:)
  pid=Process.spawn(environment, RbConfig.ruby, *args, out: log, err: [ :child, :out ])
  _, status=Process.wait2(pid)
  raise "Fixture helper failed; inspect private log" unless status.success?
end
seeded=false
begin
child!(seed_env, File.join(root, "bin/native_test"), engine, "--confirm-synthetic", "runner", "scripts/native/seo_fixture_seed.rb", log: File.join(work, "seed.log"))
seeded=true
child!(seed_env, File.join(root, "bin/native_test"), engine, "--confirm-synthetic", "runner", "scripts/native/theme_fixture_seed.rb", log: File.join(work, "theme-seed.log"))
theme_info=JSON.parse(File.read(info)).fetch("themes")
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
environment=seed_env.merge("RAILS_ENV"=>"production", "SECRET_KEY_BASE_DUMMY"=>nil, "SECRET_KEY_BASE"=>SecureRandom.hex(64), "RAILPRESS_HTTPS_ORIGIN"=>"https://localhost:58105",
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
  theme_rows=[]
  check_theme=->(name, path, expected, status = 200) do
    response=request.call("GET", path)
    raise "#{name}: status #{response.code}" unless response.code.to_i==status
    raise "#{name}: theme mismatch" if expected && !response.body.include?(%(data-theme="#{expected}"))
    theme_rows << { case: name, status: status, theme: expected }
    response
  end
  check_theme.call("initial_dusk", "/", "dusk")
  theme_token=-> { token.call(request.call("GET", "/admin/themes")) }
  harbor=theme_info.fetch("harbor")
  mutation=->(path, values) do
    response=request.call("POST", path, values.merge("authenticity_token"=>theme_token.call))
    raise "Theme mutation failed: #{response.code}" unless response.code=="303"
  end
  mutation.call("/admin/themes/#{harbor.fetch('id')}/preview", { "overlay_id"=>harbor.fetch("overlay_id").to_s })
  preview=check_theme.call("owner_preview", "/", "harbor")
  preview_html=Nokogiri::HTML(preview.body)
  raise "Preview SEO/cache leak" unless preview["cache-control"].include?("no-store") && preview["x-robots-tag"]=="noindex, nofollow" && preview_html.css('link[rel="canonical"],script[type="application/ld+json"]').empty?
  owner_cookies=cookies.dup;cookies.clear
  check_theme.call("anonymous_during_preview", "/", "dusk")
  cookies.replace(owner_cookies)
  mutation.call("/admin/themes/#{harbor.fetch('id')}/activate", { "overlay_id"=>harbor.fetch("overlay_id").to_s, "version"=>"1" })
  mutation.call("/admin/themes/stop-preview", {})
  check_theme.call("activated_harbor", "/", "harbor")
  %w[dusk harbor].each do |name|
    asset=request.call("GET", theme_info.fetch(name).fetch("asset"))
    raise "Versioned asset mismatch" unless asset.code=="200" && Digest::SHA256.hexdigest(asset.body)==theme_info.fetch(name).fetch("sha256") && asset["cache-control"].include?("immutable")
    theme_rows << { case: "retained_#{name}_asset", status: 200, sha256: Digest::SHA256.hexdigest(asset.body) }
  end
  mutation.call("/admin/themes/revert", { "version"=>"2" })
  check_theme.call("compatible_revert", "/", "dusk")
  broken=theme_info.fetch("broken")
  mutation.call("/admin/themes/#{broken.fetch('id')}/preview", { "overlay_id"=>broken.fetch("overlay_id").to_s })
  mutation.call("/admin/themes/#{broken.fetch('id')}/activate", { "overlay_id"=>broken.fetch("overlay_id").to_s, "version"=>"3" })
  mutation.call("/admin/themes/stop-preview", {})
  emergency=check_theme.call("emergency_core", "/", nil, 503)
  raise "Emergency privacy failure" unless emergency["x-robots-tag"]=="noindex, nofollow" && emergency["cache-control"].include?("no-store") && emergency.body.include?("Site temporarily unavailable")
  panel_theme=request.call("GET", "/admin/themes")
  raise "Core recovery panel unavailable or identity hidden" unless panel_theme.code=="200" && panel_theme.body.include?(broken.fetch("identity")) && !panel_theme.body.include?('data-theme="harbor"')
  mutation.call("/admin/themes/revert", { "version"=>"4" })
  check_theme.call("recovery_revert", "/", "dusk")
  # Synthetic native release-path cutover; controlled restart, no host/proxy deployment.
  release=File.join(release_root, "r2")
  FileUtils.mkdir_p(release, mode: 0o700)
  selected=IO.popen([ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z" ], &:read).split("\0").uniq
  selected.each do |relative|
    next unless relative.match?(%r{\A(?:app/|bin/|config/|db/|lib/|public/|vendor/|themes/)}) || %w[Gemfile Gemfile.lock Rakefile config.ru .ruby-version LICENSE THIRD_PARTY_NOTICES.md].include?(relative)
    next if relative.match?(%r{\Aconfig/(?:credentials|master\.key)}) || !File.file?(relative)
    raise "Symlink cannot enter fixture release" if File.symlink?(relative)
    destination=File.join(release, relative)
    FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
    FileUtils.cp(relative, destination)
  end
  FileUtils.cp_r(File.join(root, "public/assets"), File.join(release, "public/assets"))
  manifest_sha=Digest::SHA256.file(File.join(root, "public/assets/.manifest.json")).hexdigest
  raise "Compiled asset manifest changed" unless Digest::SHA256.file(File.join(release, "public/assets/.manifest.json")).hexdigest==manifest_sha
  Process.kill("TERM", -puma); Timeout.timeout(8) { Process.wait(puma) }
  release_environment=environment.merge("BUNDLE_GEMFILE"=>File.join(release, "Gemfile"))
  puma=Process.spawn(release_environment, RbConfig.ruby, "-S", "bundle", "exec", "puma", "-b", "ssl://127.0.0.1:58105?key=#{key_path}&cert=#{cert_path}", "-b", "tcp://127.0.0.1:58106", chdir: release, out: File.join(work, "puma-restart.log"), err: [ :child, :out ], pgroup: true)
  Timeout.timeout(25) do
    loop do
      begin
        break if request.call("GET", "/up").code=="200"
      rescue Errno::ECONNREFUSED, EOFError, Net::ReadTimeout
      end
      raise "Synthetic r2 Puma exited; inspect private boot log" if Process.waitpid(puma, Process::WNOHANG)
      sleep 0.1
    end
  end
  raise "New native process is not in synthetic r2" unless File.realpath("/proc/#{puma}/cwd")==File.realpath(release)
  theme_rows << { case: "synthetic_release_r2", process_cwd_verified: true, compiled_manifest_sha256: manifest_sha, controlled_restart: true, production_host: false }
  check_theme.call("persistent_theme_after_restart", "/", "dusk")
  retained=request.call("GET", harbor.fetch("asset"))
  raise "Previous digest lost after restart" unless retained.code=="200" && Digest::SHA256.hexdigest(retained.body)==harbor.fetch("sha256")
  theme_rows << { case: "old_digest_after_restart", status: 200 }
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
  File.write("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{engine}-theme-production.json", JSON.pretty_generate(environment: "production", scope: "verified synthetic native fixture only", engine: engine, target: identity, tls_peer_verified: true, process_restart: true, synthetic_release_directory_cutover: true, theme_api: 1, packages: theme_info.transform_values { |value| value.slice("identity", "sha256") }, rows: theme_rows)+"\n")
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
  if release_root && File.directory?(release_root)
    resolved=File.realpath(release_root)
    raise "unsafe synthetic release cleanup" unless resolved.start_with?("/tmp/railpress-m06-release-")
    FileUtils.remove_entry_secure(resolved)
  end
  if theme_root && File.directory?(theme_root)
    resolved=File.realpath(theme_root)
    raise "unsafe synthetic theme cleanup" unless resolved.start_with?("/tmp/railpress-m06-theme-")
    Dir.glob(File.join(resolved, "**", "*")).each { |entry| File.chmod(0o700, entry) if File.directory?(entry) && !File.symlink?(entry) }
    FileUtils.remove_entry_secure(resolved)
  end
end
