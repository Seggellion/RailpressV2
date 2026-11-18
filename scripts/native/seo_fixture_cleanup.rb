require "json"
raise "Fixture cleanup is test-only" unless Rails.env.test?
info=JSON.parse(File.read(ENV.fetch("RAILPRESS_SEO_FIXTURE_INFO")))
raise "Wrong synthetic install or records" unless Site.count==1 && Site.first.install_id==info.fetch("install_id") && User.pluck(:username)==[ "seo-fixture-owner" ] && Content.count==info.fetch("content_count")
runs=Seo::DiagnosticRun.all.map { |run|run.attributes.slice("status", "mode", "summary") }
raise "Production worker proof missing" unless ENV["RAILPRESS_SEO_FIXTURE_ABORT"] == "1" || (runs.one? && runs.first["status"]=="completed" && runs.first["summary"]["checked"]==5)
observation={ engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), scope: "real production-mode loopback fixture; not production host", runs: runs, active_sessions_before_cleanup: UserSession.count, redirects: Redirect.count, content_count: Content.count }
suffix = ENV["RAILPRESS_SEO_FIXTURE_ABORT"] == "1" ? "production-abort-observation" : "production-observation"
File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-#{suffix}.json"), JSON.pretty_generate(observation)+"\n")
SolidQueue::Job.where(class_name: "SeoDiagnosticJob").each(&:destroy!)
Seo::DiagnosticTarget.delete_all
Seo::DiagnosticRun.delete_all
Redirect.delete_all
Site.update_all(homepage_content_id: nil)
MediaReference.delete_all
MenuLocation.delete_all
Menu.update_all(published_revision_id: nil)
Menu.find_each { |menu| Navigation::Tree.ordered(menu.tree).reverse_each { |row| MenuItem.where(menu_id: menu.id, key: row["key"]).delete_all } }
MenuRevision.delete_all
Menu.delete_all
NavigationState.delete_all
ThemePreview.delete_all
ThemeState.delete_all
ThemeOverlay.delete_all
ThemeInstallation.delete_all
ContentPreview.delete_all
ContentRevision.delete_all
ContentTerm.delete_all
Content.delete_all
Term.delete_all
Taxonomy.delete_all
Site.delete_all
UserSession.delete_all
PasswordReset.delete_all
User.delete_all
AuthenticationThrottle.delete_all
puts "Exact synthetic fixture observed and cleaned"
