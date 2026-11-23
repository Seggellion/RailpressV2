require "railpress/releases"
require "railpress/releases/builder"
require "tmpdir"

module ReleaseTestSupport
  def release_setup
    @release_parent = Rails.root.join(".local/state/m11-tests")
    FileUtils.mkdir_p(@release_parent, mode: 0o700)
    @operator_root = Dir.mktmpdir("operator-", @release_parent)
    %w[inbox staging receipts clock].each { |name| Dir.mkdir(File.join(@operator_root, name), 0o700) }
    @release_signer = OpenSSL::PKey.generate_key("ED25519")
    @time_signer = OpenSSL::PKey.generate_key("ED25519")
    @status_signer = OpenSSL::PKey.generate_key("ED25519")
    @keys = [ [ @release_signer, "release" ], [ @time_signer, "time" ], [ @status_signer, "status" ] ].to_h do |key, purpose|
      [ Railpress::Releases.key_id(key), { "purpose" => purpose, "public_key" => key.public_to_pem } ]
    end
    @trust = { "format" => "railpress.trust.v1", "generation" => 1, "keys" => @keys, "revoked" => [] }
    write_trust
    @release_ticks = 1000.0
    @release_domain = "synthetic-linux-boot-domain"
    @release_clock = Railpress::SecurityClock.new(File.join(@operator_root, "clock"),
      elapsed: -> { @release_ticks }, domain: -> { @release_domain })
    @release_now = Time.utc(2026, 11, 12, 12)
    travel_to @release_now
    @release_clock.sample
    @theme_contract = [ { "id" => "dusk", "version" => "1.1.0", "digest" => "d" * 64 } ]
    @release_context = { "ruby" => RUBY_VERSION, "rails" => Rails.version,
      "database_engine" => ENV.fetch("RAILPRESS_TEST_ENGINE"), "database_version" => ENV["RAILPRESS_TEST_ENGINE"] == "postgresql" ? "16.16" : "8.4.13",
      "native_profile" => Railpress::Product::NATIVE_PROFILE, "themes" => @theme_contract }
    @operator = new_operator
    @release_fixture = build_release
    publish_fixture(@release_fixture)
  end
  def release_teardown
    travel_back
    if @operator_root
      raise "unsafe cleanup" unless File.realpath(@operator_root).start_with?(@release_parent.realpath.to_s + "/")
      FileUtils.remove_entry_secure(@operator_root)
    end
  end
  def new_operator(**options)
    Railpress::Releases::Operator.new(root: @operator_root, context: @release_context, clock: @release_clock,
      signer: @status_signer, **options)
  end
  def write_trust
    Railpress::Releases::Filesystem.atomic(File.join(@operator_root, "trust.json"), JSON.generate(@trust))
  end
  def signed(value, signer)
    { "algorithm" => "ed25519", "key_id" => Railpress::Releases.key_id(signer),
      "signature" => Base64.strict_encode64(signer.sign(nil, Railpress::Releases.canonical(value))) }
  end
  def build_release(sequence: 1, version: "2.0.0-alpha.3", channel: "development", dusk: nil)
    files = Railpress::Releases::Manifest::REQUIRED.to_h do |name|
      bytes = name == "public/assets/.manifest.json" ? "{}" : File.binread(Rails.root.join(name))
      [ name, { "bytes" => bytes, "mode" => name.start_with?("bin/") ? 0o755 : 0o644 } ]
    end
    files["lib/railpress/product.json"]["bytes"] = JSON.generate({ "format" => "railpress.product.v1", "version" => version,
      "channel" => channel, "security_clock" => 2, "theme_api" => 1, "schema" => Railpress::Product::SCHEMA, "jobs" => 1, "configuration" => Railpress::Product::CONFIGURATION })
    assets = { "admin.css" => { "digested_path" => "admin-synthetic.css" }, "admin_shell.js" => { "digested_path" => "admin-synthetic.js" } }
    files["public/assets/.manifest.json"]["bytes"] = JSON.generate(assets)
    files["public/assets/admin-synthetic.css"] = { "bytes" => "/* Synthetic release fixture */", "mode" => 0o644 }
    files["public/assets/admin-synthetic.js"] = { "bytes" => "// Synthetic release fixture\n", "mode" => 0o644 }
    compatibility = { "ruby" => ">= 3.4.12, < 3.5", "rails" => "= 8.1.4.1",
      "databases" => { "postgresql" => ">= 16.15, < 17.0", "mysql2" => ">= 8.4.13, < 8.5" },
      "schema_read" => [ Railpress::Product::SCHEMA, Railpress::Product::SCHEMA ], "schema_write" => [ Railpress::Product::SCHEMA, Railpress::Product::SCHEMA ], "jobs_read" => [ 1, 1 ], "jobs_write" => [ 1, 1 ],
      "theme_api" => 1, "themes" => @theme_contract, "configuration" => Railpress::Product::CONFIGURATION, "security_clock" => 2,
      "native_profile" => Railpress::Product::NATIVE_PROFILE, "prior_versions" => [ Railpress::Product::VERSION ],
      "assets_sha256" => Digest::SHA256.hexdigest(files["public/assets/.manifest.json"]["bytes"]) }
    metadata = { "version" => version, "channel" => channel, "sequence" => sequence,
      "published_at" => @release_now.to_i - 60, "expires_at" => @release_now.to_i + 3600,
      "changelog" => "Synthetic development release; not a public distribution.",
      "provenance" => "Original MIT Railpress source and clearly labeled synthetic fixture assets; no private source records." }
    Railpress::Releases::Builder.build(files: files, metadata: metadata, compatibility: compatibility, signer: @release_signer, dusk: dusk)
  end
  def publish_fixture(fixture)
    path = File.join(@operator_root, "inbox", fixture.fetch("release_id"))
    FileUtils.mkdir_p(path, mode: 0o700)
    { "manifest.json" => JSON.generate(fixture["manifest"]), "signature.json" => JSON.generate(fixture["signature"]),
      "package.tar.gz" => fixture["package"] }.each { |name, bytes| Railpress::Releases::Filesystem.atomic(File.join(path, name), bytes) }
    path
  end
  def altered_fixture
    fixture = Marshal.load(Marshal.dump(@release_fixture))
    yield fixture["manifest"]
    fixture["release_id"] = Digest::SHA256.hexdigest(Railpress::Releases.canonical(fixture["manifest"]))
    fixture["signature"] = signed(fixture["manifest"], @release_signer)
    publish_fixture(fixture)
    fixture
  end
  def prepare_release(id, fixture = @release_fixture, utc: @release_now.to_i)
    @operator.inspect(request_id: id, release_id: fixture["release_id"])
    challenge = @operator.challenge(request_id: id)
    statement = { "format" => "railpress.utc.v1", **challenge, "utc" => utc }
    receipt = { "statement" => statement, "signature" => signed(statement, @time_signer) }
    Railpress::Releases::Filesystem.atomic(File.join(@operator_root, "receipts", "#{id}.json"), JSON.generate(receipt))
    receipt
  end
  def stage_release(id = SecureRandom.uuid, fixture = @release_fixture)
    prepare_release(id, fixture)
    @operator.stage(request_id: id, release_id: fixture["release_id"])
  end
end
