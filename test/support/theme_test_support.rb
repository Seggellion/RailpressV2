require_relative "seo_test_support"
require_relative "../../lib/railpress/theme_fixture"
module ThemeTestSupport
  extend ActiveSupport::Concern
  include SeoTestSupport
  included do
    setup do
      freeze_time(with_usec: true)
      @previous_theme_root = ENV["RAILPRESS_THEME_ROOT"]
      ENV["RAILPRESS_THEME_ROOT"] = File.join(@private_root, "themes")
      FileUtils.mkdir_p(ENV["RAILPRESS_THEME_ROOT"], mode: 0o700)
      @signer = OpenSSL::PKey.generate_key("ED25519")
      @keys = { Digest::SHA256.hexdigest(@signer.public_to_der) => @signer.public_to_pem }
      File.write(File.join(Themes::Storage.root, "trusted-keys.json"), JSON.generate(@keys), perm: 0o600)
    end
    teardown do
      ENV["RAILPRESS_THEME_ROOT"] = @previous_theme_root
      travel_back
    end
  end
  def package_directory(id = "harbor", version: "1.0.0", mutate: nil)
    directory = File.join(@private_root, "candidate-#{SecureRandom.hex(6)}")
    Railpress::ThemeFixture.build(directory, root: Rails.root, signer: @signer, id: id, version: version, mutate: mutate)
    directory
  end
  def stage(id = "harbor", version: "1.0.0", mutate: nil)
    Themes::Manager.stage!(actor: @owner, directory: package_directory(id, version: version, mutate: mutate))
  rescue Railpress::ThemeSmoke::Rejected => error
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M08')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-smoke-rejection-#{SecureRandom.hex(4)}.json"), JSON.pretty_generate(error.diagnostic) + "\n")
    raise
  end
  def prepare_preview(package, overlay = package.theme_overlays.first)
    Themes::Manager.preview!(actor: @owner, installation: package, overlay: overlay, authentication_token: UserSession.issue!(@owner))
  end
  def activate(package, overlay = package.theme_overlays.first, version: ThemeState.first&.lock_version || 0)
    token = UserSession.issue!(@owner)
    Themes::Manager.preview!(actor: @owner, installation: package, overlay: overlay, authentication_token: token)
    Themes::Manager.activate!(actor: @owner, installation: package, overlay: overlay, version: version)
  ensure
    if token
      ThemePreview.where(session_digest: Digest::SHA256.hexdigest(token)).delete_all
      UserSession.where(token_digest: Digest::SHA256.hexdigest(token)).delete_all
    end
  end
end
