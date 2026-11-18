# Exact named disposable fixture controls; never accepts an arbitrary database.
require "json"
require "active_storage/service/disk_service"
raise "test-only" unless Rails.env.test? && ENV["RAILPRESS_TEST_CONFIRM"] == "railpress-synthetic-only"
target = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE")); Railpress::TestDatabase.verify!(target)
info = JSON.parse(File.read(ENV.fetch("RAILPRESS_DUSK_FIXTURE_INFO")))
raise "wrong fixture" unless Site.count == 1 && Site.first.install_id == info.fetch("install_id") && User.pluck(:username) == [ "dusk-fixture-owner" ] && Content.count == info.fetch("content_count")
owner = User.first
case ENV.fetch("RAILPRESS_DUSK_CONTROL")
when "blog" then Site.first.update!(home_mode: "blog")
when "static" then Site.first.update!(home_mode: "static", homepage_content_id: info.fetch("home_id"))
when "empty"
  info["public_ids"] = Content.publicly_visible.pluck(:id)
  File.write(ENV.fetch("RAILPRESS_DUSK_FIXTURE_INFO"), JSON.generate(info), perm: 0o600)
  Content.where(id: info["public_ids"]).each { |record| Editorial::Workflow.update!(actor: owner, content: record, expected_version: record.lock_version, event: "unpublish") }
  Site.first.update!(home_mode: "static", homepage_content_id: nil)
when "restore"
  Content.where(id: info.fetch("public_ids")).each { |record| Editorial::Workflow.update!(actor: owner, content: record, expected_version: record.lock_version, event: "publish") }
  Site.first.update!(home_mode: "static", homepage_content_id: info.fetch("home_id"))
when "missing_media", "restore_media"
  asset = MediaAsset.find(info.fetch("asset_id"))
  backup = File.join(File.dirname(ENV.fetch("RAILPRESS_DUSK_FIXTURE_INFO")), "original-media.bin")
  production = ActiveStorage::Service::DiskService.new(root: ENV.fetch("RAILPRESS_DUSK_PRODUCTION_MEDIA"))
  services = [ asset.blob.service, production ]
  if ENV["RAILPRESS_DUSK_CONTROL"] == "missing_media"
    File.binwrite(backup, asset.blob.download); File.chmod(0o600, backup)
    services.each { |service| service.delete(asset.blob.key) }
  else
    services.each { |service| service.upload(asset.blob.key, StringIO.new(File.binread(backup))) }
  end
when "customization", "brand_stress"
  package = ThemeInstallation.find(info.fetch("package_id"))
  overlay = if ENV["RAILPRESS_DUSK_CONTROL"] == "customization"
    package.theme_overlays.find(info.fetch("candidate_id"))
  else
    Themes::Manager.overlay!(actor: owner, installation: package, attributes: { brand_label: ("非常に長い名前 Café North Coast " * 3).strip })
  end
  token = UserSession.issue!(owner)
  Themes::Manager.preview!(actor: owner, installation: package, overlay: overlay, authentication_token: token)
  Themes::Manager.activate!(actor: owner, installation: package, overlay: overlay, version: ThemeState.first.lock_version)
  ThemePreview.delete_all; UserSession.delete_all
when "artwork_proof"
  require "vips"
  asset = MediaAsset.find(info.fetch("asset_id"))
  image = Vips::Image.new_from_buffer(asset.blob.download, "")
  samples = [ [ 200, 200 ], [ 600, 400 ], [ 900, 200 ] ].map { |x, y| image.getpoint(x, y).map(&:to_i) }
  raise "fixture artwork" unless samples == [ [ 69, 91, 85 ], [ 167, 77, 49 ], [ 244, 239, 228 ] ]
  File.write(Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-fixture-artwork.json"), JSON.pretty_generate(samples) + "\n")
when "broken", "recover"
  state = ThemeState.first
  if ENV["RAILPRESS_DUSK_CONTROL"] == "broken"
    package = ThemeInstallation.find(info.fetch("broken_id")); overlay = package.theme_overlays.first
    token = UserSession.issue!(owner)
    Themes::Manager.preview!(actor: owner, installation: package, overlay: overlay, authentication_token: token)
    Themes::Manager.activate!(actor: owner, installation: package, overlay: overlay, version: state.lock_version)
    ThemePreview.delete_all; UserSession.delete_all
  else
    Themes::Manager.revert!(actor: owner, version: state.lock_version)
  end
when "cleanup"
  blobs = MediaAsset.pluck(:blob_id, :thumbnail_blob_id).flatten.compact
  Site.update_all(homepage_content_id: nil)
  MenuLocation.delete_all; Menu.update_all(published_revision_id: nil)
  Menu.find_each { |menu| Navigation::Tree.ordered(menu.tree).reverse_each { |row| MenuItem.where(menu_id: menu.id, key: row["key"]).delete_all } }
  MenuRevision.delete_all; Menu.delete_all; NavigationState.delete_all
  MediaReference.delete_all; ThemePreview.delete_all; ThemeState.delete_all; ThemeOverlay.delete_all; ThemeInstallation.delete_all
  ContentPreview.delete_all; ContentRevision.delete_all; ContentTerm.delete_all; Content.delete_all
  MediaAsset.delete_all; MediaUpload.delete_all
  ActiveStorage::Blob.where(id: blobs).find_each(&:purge)
  Term.delete_all; Taxonomy.delete_all; UserSession.delete_all; PasswordReset.delete_all; Site.delete_all; User.delete_all; AuthenticationThrottle.delete_all
  raise "jobs remain" unless SolidQueue::Job.count.zero?
else raise "unknown control"
end
puts "Named synthetic Dusk control completed"
