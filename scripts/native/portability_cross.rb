# Explicit isolated M15 qualification harness. Never loaded by application boot.
require "json"
require "fileutils"
require "vips"
require Rails.root.join("lib/railpress/dusk_package")
require Rails.root.join("test/support/generic_site_fixture")
require Rails.root.join("test/support/portability_test_support")
module PortabilityCross
  extend PortabilityTestSupport
  module_function
  def run
    raise "M15 synthetic profile only" unless Rails.env.test? && ENV["RAILPRESS_TEST_CONFIRM"] == "railpress-synthetic-only" && %w[m15_source m15_target].include?(ENV["RAILPRESS_TEST_PROFILE"])
    engine = ENV.fetch("RAILPRESS_TEST_ENGINE")
    config = Railpress::TestDatabase.load!(root: Rails.root, engine: engine)
    identity = Railpress::TestDatabase.verify!(config)
    phase = ARGV.fetch(0)
    run = ENV.fetch("RAILPRESS_M15_CROSS_RUN", "cross-01")
    raise "bounded evidence run" unless run.match?(/\Across-\d\d\z/)
    @semantic_checks = 0
    raise "phase/profile mismatch" unless phase == "source" && ENV["RAILPRESS_TEST_PROFILE"] == "m15_source" || phase == "target" && ENV["RAILPRESS_TEST_PROFILE"] == "m15_target"
    source_engine = phase == "target" ? ARGV.fetch(1) : nil
    base = Rails.root.join(".local/state/m15", run, phase == "target" ? "target-#{engine}-from-#{source_engine}" : "source-#{engine}")
    FileUtils.mkdir_p(base, mode: 0o700)
    ENV["RAILPRESS_PRIVATE_STATE_ROOT"] = base.join("bootstrap").to_s
    ENV["RAILPRESS_THEME_ROOT"] = base.join("themes").to_s
    raise "Fresh fixture only; never overwrite existing content" if Site.exists? || User.exists?
    state = Railpress::BootstrapState.for_application
    password = SecureRandom.urlsafe_base64(30)
    attributes = { title: "Independent destination", tagline: "Synthetic M15 qualification", canonical_origin: phase == "source" ? "https://railpress.org" : "https://destination.example.invalid", locale: "en", timezone: "America/Vancouver", indexing_enabled: true, home_mode: "static" }
    Setup::Complete.call(state: state, claim: state.claim!(state.issue!), site_attributes: attributes,
      owner_attributes: { username: "portable-owner", email: "portable-owner@example.invalid", password: password, password_confirmation: password })
    @owner = User.find_by!(role: "owner")
    File.write(base.join("login.json"), JSON.generate(username: @owner.username, password: password), perm: 0o600)
    site = Site.first
    common = Rails.root.join(".local/state/m15/cross-01/theme-source")
    FileUtils.mkdir_p(common, mode: 0o700)
    key_path = common.join("synthetic.key")
    File.write(key_path, OpenSSL::PKey.generate_key("ED25519").private_to_pem, perm: 0o600) unless key_path.exist?
    signer = OpenSSL::PKey.read(key_path.read)
    package_path = common.join("dusk").to_s
    Railpress::DuskPackage.build(package_path, root: Rails.root.to_s, signer: signer) unless File.directory?(package_path)
    FileUtils.mkdir_p(ENV.fetch("RAILPRESS_THEME_ROOT"), mode: 0o700)
    File.write(File.join(ENV.fetch("RAILPRESS_THEME_ROOT"), "trusted-keys.json"), JSON.generate(Digest::SHA256.hexdigest(signer.public_to_der)=>signer.public_to_pem), perm: 0o600)
    package = Themes::Manager.stage!(actor: @owner, directory: package_path)
    token = UserSession.issue!(@owner); session_id = UserSession.resolve(token).id
    if phase == "source"
      ENV["RAILPRESS_INSTALL_THEME"] = package_path
      Installation::Starter.call(owner: @owner, site: site, choices: { "brand_label"=>"Synthetic source" })
      ENV["RAILPRESS_GENERIC_FIXTURE"] = "generic-synthetic-only"
      fixture = GenericSiteFixture.load!(actor: @owner) # No uncleared M14 logo.
      GenericSiteFixture.corpus.fetch("articles").each do |row|
        content = fixture.fetch(:posts).fetch(row.fetch("id"))
        metadata = { "source"=>row.slice("id", "canonical_path", "body_sha256", "content_provenance"),
          "review"=>row.except("title", "slug", "excerpt", "meta_title", "meta_description", "blocks", "body_file", "body_sha256", "internal_links"),
          "authorship"=>row.slice("public_byline", "independent_fact_checker", "owner_review", "publication_date"), "internal_links"=>row.fetch("internal_links") }
        Portability::EditorialMetadata.attach!(actor: @owner, content: content, expected_version: content.lock_version, metadata: metadata)
      end
      # Additional original synthetic cases exercise histories, variants, blocks,
      # taxonomy, redirects, live/private edits and scheduling metadata.
      raw = Vips::Image.black(80, 40).new_from_image([ 36, 91, 120 ]).write_to_buffer(".png")
      asset = MediaLibrary::Upload.call(actor: @owner, io: StringIO.new(raw), filename: "synthetic.png", content_type: "image/png", attributes: { "title"=>"M15 original synthetic image", "alt_text"=>"A blue rectangle", "caption"=>"Original synthetic caption", "attribution"=>"Synthetic qualification fixture", "license_notes"=>"Original synthetic work cleared for local qualification" })
      term = Editorial::Terms.create!(actor: @owner, kind: "tag", name: "Café 東京", slug: "unicode-test")
      post = Editorial::Workflow.create!(actor: @owner, kind: "Post", attributes: { "title"=>"Synthetic portable story café 東京", "slug"=>"portable-original", "body"=>"<p>Unicode café 東京 مرحبا.</p>", "excerpt"=>"Synthetic public summary", "meta_title"=>"Portable SEO", "meta_description"=>"Synthetic portability proof", "term_ids"=>[ term.id ], "featured_media_id"=>asset.id, "blocks"=>[ { "type"=>"image", "media_id"=>asset.id, "caption"=>"Per-use caption" } ] })
      Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "publish")
      Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "unpublish")
      Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, attributes: { "slug"=>"portable-renamed" })
      Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "publish")
      Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, attributes: { "body"=>"<p>PRIVATE WORKING CROSS ENGINE CANARY café 東京.</p>" })
      scheduled = Editorial::Workflow.create!(actor: @owner, kind: "Post", attributes: { "title"=>"Synthetic future", "slug"=>"synthetic-future", "body"=>"<p>Never automatically scheduled by import.</p>", "visibility"=>"private" })
      # Inject source scheduling metadata in this isolated fixture, without a
      # wall-clock-dependent due job or a claim of qualified UTC.
      scheduled.managed_change { scheduled.update!(status: "scheduled", scheduled_at: Time.utc(2035, 1, 1), scheduled_by_id: @owner.id) }
      rights = { asset.id.to_s=>{ "status"=>"cleared", "license"=>asset.license_notes, "attribution"=>asset.attribution } }
      public_scope = { "mode"=>"public", "content_ids"=>[], "history"=>false, "author_labels"=>{}, "media_rights"=>rights, "menus"=>true, "appearance"=>true }
      public_export = Portability::Exports.request!(actor: @owner, session_id: session_id, scope: public_scope); Portability::Exports.perform!(public_export)
      private_scope = public_scope.merge("mode"=>"owner_private", "content_ids"=>Content.order(:id).pluck(:id), "history"=>true, "author_labels"=>{ @owner.id.to_s=>"Approved synthetic author label" })
      private_export = Portability::Exports.request!(actor: @owner, session_id: session_id, scope: private_scope); Portability::Exports.perform!(private_export)
      public_bytes = Portability::Store.read(public_export); private_bytes = Portability::Store.read(private_export)
      m, = Railpress::SiteArchive.read(private_bytes)
      raise "Private leak" if public_bytes.include?("PRIVATE WORKING CROSS ENGINE CANARY") || GenericSiteFixture.corpus["articles"].any? { |r| public_bytes.include?(r["title"]) }
      raise "Missing twenty" unless m["content"].count { |r| r["working"]["portable_metadata"].dig("authorship", "owner_review") == "AWAITING OWNER REVIEW" } == 20
      File.binwrite(base.join("public.railpress"), public_bytes); File.chmod(0o600, base.join("public.railpress"))
      File.binwrite(base.join("private.railpress"), private_bytes); File.chmod(0o600, base.join("private.railpress"))
      report = { engine: engine, identity: identity, source_digest: Portability::Imports.destination_digest(site.reload), inventory: m.slice("content", "revisions", "terms", "media", "menus", "redirects").transform_values(&:length),
        public_archive_sha256: public_export.archive_sha256, private_archive_sha256: private_export.archive_sha256, public_twenty_excluded: true, private_twenty_complete: true, source_fixture: "controlled fresh copy; original files and base databases untouched", theme: package.digest }
      File.write(base.join("source-seal.json"), JSON.pretty_generate(report), perm: 0o600)
      write_report("#{engine}-source.json", report)
    else
      source_engine = ARGV.fetch(1)
      raise "source engine" unless %w[postgresql mysql2].include?(source_engine)
      source_base = Rails.root.join(".local/state/m15/cross-01", "source-#{source_engine}")
      bytes = File.binread(source_base.join("private.railpress")); manifest, = Railpress::SiteArchive.read(bytes)
      batch = Portability::Imports.submit!(actor: @owner, session_id: session_id, io: StringIO.new(bytes), idempotency_key: Digest::SHA256.hexdigest("#{source_engine}-#{engine}-private-01"))
      Portability::Worker.perform!(batch)
      d = portable_decisions(manifest)
      d["authors"] = manifest["authors"].to_h { |r| [ r["ref"], @owner.id ] }
      d["unassigned"] = manifest["content"].select { |r| r["working"]["author_ref"].nil? }.to_h { |r| [ r["ref"], @owner.id ] }
      d.merge!("settings"=>"apply_nonsensitive", "appearance"=>"stage_compatible", "locations"=>"stage_unassigned")
      Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version, decisions: d)
      Portability::Worker.perform!(batch)
      raise "Staging incomplete" unless batch.reload.state == "staged" && Content.publicly_visible.count.zero?
      manifest["content"].each do |source|
        content = Content.find(Portability::Stage.target(batch, "content", source["ref"]))
        raise "Content loss" unless content.body == source["working"]["body"] && content.portable_metadata == source["working"]["portable_metadata"] && content.status == "draft" && content.visibility == "private" && content.scheduled_at.nil?
      end
      # Re-export before activation proves exact approved source revision numbers,
      # timestamps, bodies and stable content/media/taxonomy/menu identities.
      rights = manifest["media"].to_h { |r| [ Portability::Stage.target(batch, "media", r["ref"]).to_s, r["rights"] ] }
      scope = { "mode"=>"owner_private", "content_ids"=>Content.order(:id).pluck(:id), "history"=>true, "author_labels"=>{ @owner.id.to_s=>"Approved synthetic author label" }, "media_rights"=>rights, "menus"=>true, "appearance"=>false }
      output = Portability::Exports.request!(actor: @owner, session_id: session_id, scope: scope); Portability::Exports.perform!(output)
      roundtrip, = Railpress::SiteArchive.read(Portability::Store.read(output))
      by_ref = roundtrip["revisions"].index_by { |r| r["ref"] }
      manifest["revisions"].each do |r|
        copy = by_ref.fetch(r["ref"])
        # Destination author accounts and media IDs are remapped; portable labels
        # and stable external references carry those relationships instead.
        raise "Revision loss" unless r.values_at("ref", "content_ref", "number", "event", "created_at", "history") == copy.values_at("ref", "content_ref", "number", "event", "created_at", "history") && r["snapshot"]["body"] == copy["snapshot"]["body"]
      end
      live_refs = manifest["content"].select { |r| r["live"] && r["history"]["state"] == "published" && r["working"]["portable_metadata"].fetch("review", {}).blank? }.map { |r| r["ref"] }
      overlay = ThemeOverlay.find(batch.report.fetch("overlay_id"))
      Themes::Manager.preview!(actor: @owner, installation: package, overlay: overlay, authentication_token: token)
      Portability::Activation.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, content_refs: live_refs, menus: true, settings: true, appearance: true)
      Portability::Worker.perform!(batch)
      raise "Activation incomplete" unless batch.reload.state == "complete"
      final_export = Portability::Exports.request!(actor: @owner, session_id: session_id, scope: scope.merge("appearance" => true))
      Portability::Exports.perform!(final_export)
      final, = Railpress::SiteArchive.read(Portability::Store.read(final_export))
      equivalent!("author labels and portable identities", manifest["authors"].sort_by { |r| r["ref"] }, final["authors"].sort_by { |r| r["ref"] })
      %w[terms media redirects appearance].each do |kind|
        expected = manifest[kind]; actual = final[kind]
        if expected.is_a?(Array)
          sort = ->(rows) { rows.sort_by { |r| r["ref"] || r["path"] } }
          expected = sort.call(expected); actual = sort.call(actual)
        end
        equivalent!(kind, expected, actual)
      end
      final_content = final["content"].index_by { |r| r["ref"] }
      manifest["content"].each do |record|
        copy = final_content.fetch(record["ref"])
        fields = Portability::Format::SNAPSHOT - [ "visibility" ]
        equivalent!("working snapshot #{record['ref']}", record["working"].slice(*fields), copy["working"].slice(*fields))
        equivalent!("source history #{record['ref']}", record["history"], copy["history"])
        equivalent!("approved live snapshot #{record['ref']}", record["live"], copy["live"]) if live_refs.include?(record["ref"])
      end
      final_menus = final["menus"].index_by { |r| r["ref"] }
      normalize_tree = ->(rows) { rows&.sort_by { |r| r["ref"] } }
      manifest["menus"].each do |record|
        copy = final_menus.fetch(record["ref"])
        equivalent!("menu name", record["name"], copy["name"])
        %w[draft live].each { |key| equivalent!("menu #{key}", normalize_tree.call(record[key]), normalize_tree.call(copy[key])) }
        equivalent!("independent menu locations", record["locations"].sort_by { |r| [ r["theme"], r["key"] ] }, copy["locations"].sort_by { |r| [ r["theme"], r["key"] ] })
      end
      final_revisions = final["revisions"].index_by { |r| r["ref"] }
      manifest["revisions"].each { |r| equivalent!("full source revision", r, final_revisions.fetch(r["ref"])) }
      site_keys = %w[title tagline locale timezone indexing_enabled home_mode homepage_ref organization_name]
      equivalent!("approved nonsensitive site settings", manifest["site"].slice(*site_keys), final["site"].slice(*site_keys))
      private_posts = Content.where(status: "draft", visibility: "private").select { |c| c.portable_metadata.dig("authorship", "owner_review") == "AWAITING OWNER REVIEW" }
      raise "Twenty privacy loss" unless private_posts.length == 20 && private_posts.all? { |c| c.published_at.nil? && c.published_snapshot.nil? } && OfficialNewsReview.count.zero?
      raise "Source unexpectedly changed" unless Digest::SHA256.hexdigest(File.binread(source_base.join("private.railpress"))) == JSON.parse(source_base.join("source-seal.json").read).fetch("private_archive_sha256")
      report = { source: source_engine, destination: engine, identity: identity, batch: batch.public_id, state: batch.state, inventory: manifest.slice("content", "revisions", "terms", "media", "menus", "redirects").transform_values(&:length),
        all_staged_private: true, content_bodies_metadata_equal: true, revision_identities_numbers_dates_bodies_equal: true, media_hashes_verified: true, active_public_content: Content.publicly_visible.count,
        private_twenty_preserved: private_posts.length, source_archive_unchanged: true, destination_origin_retained: site.reload.canonical_origin == "https://destination.example.invalid", theme: ThemeState.first.active_installation.digest,
        semantic_checks: @semantic_checks, full_revision_snapshots_equal: true, taxonomy_media_navigation_settings_seo_equal: true,
        representational_rules: "Historical UTC strings retain up to nine fractional digits in source journal. Native times are destination microseconds and never replace source history. New operational create/activation audits are distinct; staged current visibility is intentionally private." }
      write_report("#{source_engine}-to-#{engine}.json", report)
    end
  end
  def write_report(name, report)
    path = Rails.root.join("docs/evidence/M15", ENV.fetch("RAILPRESS_M15_CROSS_RUN", "cross-01"), name)
    raise "Preserve previous evidence" if path.exist?
    File.write(path, JSON.pretty_generate(report) + "\n")
    puts JSON.generate(report)
  end
  def equivalent!(label, expected, actual)
    @semantic_checks += 1
    raise "Semantic mismatch: #{label}" unless expected == actual
  end
end
PortabilityCross.run
