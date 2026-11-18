require_relative "identity_test_support"
require Rails.root.join("lib/railpress/dusk_package")

module InstallationTestSupport
  extend ActiveSupport::Concern
  include IdentityTestSupport
  included do
    setup do
      # Installer cases must also run alone in a fresh native checkout. Do not
      # depend on a media test having created this positively identified root.
      media = Rails.root.join(".local/state/media/test", ENV.fetch("RAILPRESS_TEST_ENGINE"))
      FileUtils.mkdir_p(media, mode: 0o700)
      raise "Unsafe installer media fixture" unless !media.symlink? && media.realpath == media && media.stat.uid == Process.uid
      File.chmod(0o700, media)
      service = ActiveStorage::Blob.service
      if service.is_a?(ActiveStorage::Service::DiskService)
        exact = Pathname.new(service.root)
        raise "Unsafe exact installer media fixture" unless exact.to_s.start_with?(media.to_s + "/") || exact == media
        FileUtils.mkdir_p(exact, mode: 0o700)
        raise "Unsafe exact installer media fixture" unless !exact.symlink? && exact.realpath == exact && exact.stat.uid == Process.uid
        File.chmod(0o700, exact)
      end
      @install_env = %w[RAILPRESS_HTTPS_ORIGIN RAILPRESS_INSTALL_THEME RAILPRESS_THEME_ROOT].to_h { |key| [ key, ENV[key] ] }
      ENV["RAILPRESS_HTTPS_ORIGIN"] = site_attributes[:canonical_origin]
      ENV["RAILPRESS_THEME_ROOT"] = File.join(@private_root, "themes")
      FileUtils.mkdir_p(ENV["RAILPRESS_THEME_ROOT"], mode: 0o700)
      signer = OpenSSL::PKey.generate_key("ED25519") # Synthetic qualification only.
      File.write(File.join(ENV["RAILPRESS_THEME_ROOT"], "trusted-keys.json"), JSON.generate(Digest::SHA256.hexdigest(signer.public_to_der) => signer.public_to_pem), perm: 0o600)
      ENV["RAILPRESS_INSTALL_THEME"] = File.join(@private_root, "dusk-candidate")
      Railpress::DuskPackage.build(ENV["RAILPRESS_INSTALL_THEME"], root: Rails.root, signer: signer)
    end
    teardown do
      @install_env.each { |key, value| ENV[key] = value }
    end
  end
  def prepare_install_schema
    @state.issue! unless File.exist?(File.join(@private_root, "setup.json"))
    Installation::Schema.prepare!(state: @state, confirmation: Installation::Configuration.fingerprint)
  end
  def install_fields(step)
    case step
    when "environment" then {}
    when "database" then Installation::Configuration.public_fields.merge("use_operator_credentials" => "1")
    when "storage" then { "backend" => "local", "storage_limits_ack" => "1" }
    when "identity" then site_attributes.stringify_keys.merge("indexing_enabled" => "0")
    when "owner" then owner_attributes.stringify_keys
    when "membership" then { "membership_mode" => "disabled", "member_registration_enabled" => "0", "member_email_required" => "1" }
    when "appearance" then { "brand_label" => "A new beginning", "about" => "1", "contact" => "1" }
    end
  end
  def advance_install(client = self, step = nil, fields: nil)
    value = Installation::Progress.new(@state).read
    step ||= value.fetch("step")
    token = csrf_token_for(client, "/setup?step=#{step}")
    client.post("/setup/steps/#{step}", params: { authenticity_token: token, revision: value.fetch("revision"), fields: fields || install_fields(step) })
    assert_equal 303, client.response.status, client.response.body
    csrf_token_for(client, "/setup")
  end
  def review_install(client = self)
    prepare_install_schema
    secret = @state.issue!
    token = csrf_token_for(client, "/setup")
    client.post("/setup/claim", params: { setup_secret: secret, authenticity_token: token })
    assert_equal 303, client.response.status
    Installation::Progress::STEPS[0...-1].each { |step| advance_install(client, step) }
    csrf_token_for(client, "/setup")
  end
  def finish_params(csrf)
    { authenticity_token: csrf, revision: Installation::Progress.new(@state).read.fetch("revision") }
  end
end
