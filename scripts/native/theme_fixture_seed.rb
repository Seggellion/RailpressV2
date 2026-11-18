# Test-only reference package preparation; never accepts an unknown database.
require Rails.root.join("lib/railpress/theme_fixture")
raise "verified test only" unless Rails.env.test? && ENV["RAILPRESS_TEST_CONFIRM"] == "railpress-synthetic-only"
info_path = ENV.fetch("RAILPRESS_SEO_FIXTURE_INFO")
info = JSON.parse(File.read(info_path))
raise "wrong synthetic install" unless Site.count == 1 && Site.first.install_id == info.fetch("install_id") && User.pluck(:username) == [ "seo-fixture-owner" ]
root = Themes::Storage.root
signer = OpenSSL::PKey.generate_key("ED25519")
File.write(File.join(root, "trusted-keys.json"), JSON.generate(Digest::SHA256.hexdigest(signer.public_to_der) => signer.public_to_pem), perm: 0o600)
owner = User.first
packages = {}
[ [ "dusk", "1.0.0" ], [ "harbor", "1.0.0" ], [ "harbor", "2.0.0" ] ].each do |id, version|
  directory = File.join(root, "candidate-#{id}-#{version}")
  mutation = if version == "2.0.0"
    ->(manifest, dir) { Railpress::ThemeFixture.replace(manifest, dir, "templates/front.html.erb", '<% raise "synthetic runtime failure" if theme.site.title == "Railpress SEO fixture" %><h1><%= theme.site.title %></h1>') }
  end
  Railpress::ThemeFixture.build(directory, root: Rails.root, signer: signer, id: id, version: version, mutate: mutation)
  package = Themes::Manager.stage!(actor: owner, directory: directory)
  packages[version == "2.0.0" ? "broken" : id] = { "id" => package.id, "overlay_id" => package.theme_overlays.first.id, "asset" => "/theme-assets/#{id}/#{version}/#{package.digest}/public.css", "sha256" => package.manifest["assets"]["public"]["sha256"], "identity" => package.public_identity }
end
dusk = ThemeInstallation.find(packages["dusk"]["id"])
Themes::Manager.preview!(actor: owner, installation: dusk, overlay: dusk.theme_overlays.first, authentication_token: UserSession.issue!(owner))
Themes::Manager.activate!(actor: owner, installation: dusk, overlay: dusk.theme_overlays.first, version: 0)
ThemePreview.delete_all
UserSession.delete_all
info["themes"] = packages
File.write(info_path, JSON.generate(info))
puts "Three ephemeral signed original packages production-smoked; Dusk API fixture active"
