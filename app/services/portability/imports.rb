module Portability
  module Imports
    class Conflict < StandardError; end
    module_function
    def submit!(actor:, session_id:, io:, idempotency_key:)
      raise Format::Invalid, "idempotency_key" unless idempotency_key.is_a?(String) && Format::SHA.match?(idempotency_key)
      newly_created = false
      transferring = false
      batch = Authority.locked(actor: actor, session_id: session_id) do |site, user, session|
        existing = ImportBatch.find_by(site: site, idempotency_key: idempotency_key)
        if existing
          existing
        else
          newly_created = true
          receipt = ImportBatch.create!(site: site, actor: user, state: "receiving", idempotency_key: idempotency_key,
            approval_session_id: session.id, auth_version: user.auth_version, archive_sha256: "0" * 64, archive_bytes: 1,
            report: { "resume_state" => "receiving", "upload_verified" => false })
          ImportBatch.event!(receipt, "upload_receipt_created")
          receipt
        end
      end
      receiving = batch.state == "receiving" || batch.state == "failed" && batch.report["resume_state"] == "receiving"
      unless receiving
        verify_duplicate!(batch, io)
        return batch
      end
      Store.upload_lock(batch.public_id) do
        raise Conflict, "The interrupted transfer was never verified. Start a new upload with a new request key." if !newly_created && batch.archive_sha256 == "0" * 64
        transferring = true
        Authority.locked(actor: actor, session_id: session_id) do |site, user, session|
          batch.lock!
          raise Conflict, "Upload receipt changed." unless batch.site_id == site.id && (batch.state == "receiving" || batch.state == "failed" && batch.report["resume_state"] == "receiving")
          batch.update!(actor: user, approval_session_id: session.id, auth_version: user.auth_version, state: "receiving", failure: nil)
        end
        Store.clean_upload_parts!(batch.public_id)
        if File.exist?(Store.path(batch.public_id))
          verify_duplicate!(batch, io)
          Store.read(batch)
        else
          Store.write(batch.public_id, io) do |sha, size|
            Authority.record_locked(batch) do
              raise Conflict, "Idempotency key already belongs to different bytes." unless batch.archive_sha256 == "0" * 64 || batch.archive_sha256 == sha && batch.archive_bytes == size
              batch.update!(archive_sha256: sha, archive_bytes: size, report: batch.report.merge("upload_verified" => true))
              ImportBatch.event!(batch, "upload_bytes_verified", { "sha256" => sha, "bytes" => size })
            end
          end
        end
        Authority.record_locked(batch) do
          batch.update!(state: "queued", report: batch.report.merge("resume_state" => "queued", "upload_verified" => true))
          ImportBatch.event!(batch, newly_created ? "archive_received" : "upload_recovered", { "sha256" => batch.archive_sha256, "bytes" => batch.archive_bytes })
        end
      end
      batch
    rescue StandardError => error
      if batch && (newly_created || transferring)
        batch.with_lock { batch.update!(state: "failed", failure: error.class.name[0, 200], report: batch.report.merge("resume_state" => "receiving")) }
      end
      raise
    end
    def verify_duplicate!(batch, io)
      digest = Digest::SHA256.new; count = 0
      while (bytes = io.read(16_384)) && !bytes.empty?
        count += bytes.bytesize; raise Format::Invalid, "archive_size" if count > Railpress::PortabilityContract::MAX_ARCHIVE
        digest.update(bytes)
      end
      raise Conflict, "Idempotency key already belongs to different bytes." unless count == batch.archive_bytes && digest.hexdigest == batch.archive_sha256
    end
    def destination_digest(site)
      # Working and published versions plus immutable identities, assignments and
      # settings bind the dry run. Authentication/operational state is excluded.
      inventory = { "site" => site.attributes.slice("title", "tagline", "canonical_origin", "locale", "timezone", "indexing_enabled", "home_mode", "homepage_content_id", "organization_name", "privacy_first_anonymous", "privacy_revision"),
        "content" => Content.order(:id).pluck(:id, :lock_version), "terms" => Term.order(:id).map { |r| r.attributes.slice("id", "taxonomy_id", "name", "slug") },
        "media" => MediaAsset.order(:id).pluck(:id, :lock_version, :state, :sha256, :thumbnail_sha256),
        "menus" => Menu.order(:id).pluck(:id, :lock_version), "locations" => MenuLocation.order(:id).map(&:attributes),
        "redirects" => Redirect.order(:id).pluck(:source_path, :target_content_id), "theme" => ThemeState.find_by(site: site)&.attributes }
      Digest::SHA256.hexdigest(Railpress::SiteArchive.canonical(inventory))
    end
    def inspect!(batch)
      bytes = Store.read(batch)
      manifest, payloads = Railpress::SiteArchive.read(bytes)
      Format.check!(manifest, payloads)
      Authority.record_locked(batch) do |site, _user, _session|
        raise Conflict, "Inspection is only available before staging." unless %w[queued inspecting review failed needs_approval blocked].include?(batch.state) && batch.import_items.empty?
        report = dry_run(site, manifest)
        batch.update!(state: "review", manifest: manifest, format_version: manifest.fetch("version"),
          normalized_sha256: Digest::SHA256.hexdigest(Railpress::SiteArchive.canonical(manifest)),
          baseline_sha256: destination_digest(site), report: report, failure: nil, progress: 0, total: 0)
        ImportBatch.event!(batch, "dry_run", report.except("conflicts"))
      end
      batch
    end
    def dry_run(site, manifest)
      conflicts = []
      manifest["content"].each do |r|
        w = r["working"]; existing = Content.find_by(type: w["type"], slug_key: Railpress::ContentRoutes.content_key(w["type"], w["slug"]))
        conflicts << { "ref" => r["ref"], "kind" => "content_path", "path" => Railpress::ContentRoutes.path(w["type"], w["slug"]), "target_id" => existing.id, "resolution" => "Choose a free explicit slug or verify an unchanged prior import match." } if existing
        matches = previous_match(site, "content", r)
        conflicts << { "ref" => r["ref"], "kind" => "existing_identity", "match_id" => matches&.target_id, "resolution" => "Explicit unchanged match required; existing data cannot be overwritten." } if PortabilityIdentity.exists?(public_id: r["ref"]) || matches
        conflicts << { "ref" => r["ref"], "kind" => "authorship", "author_ref" => w["author_ref"], "resolution" => "Explicitly choose a destination account. No account will be created." }
      end
      manifest["terms"].each do |r|
        taxonomy = Taxonomy.find_by(kind: r["kind"]); existing = taxonomy && Term.find_by(taxonomy: taxonomy, slug_key: Railpress::ContentRoutes.key(r["slug"]))
        conflicts << { "ref" => r["ref"], "kind" => "taxonomy_path", "target_id" => existing.id, "same_name" => existing.name == r["name"], "resolution" => "Explicitly match identical taxonomy or choose a free slug; names alone never merge." } if existing
      end
      manifest["media"].each { |r| conflicts << { "ref" => r["ref"], "kind" => "rights", "resolution" => "Reconfirm current rights and choose new media or an exact destination match." } }
      manifest["menus"].each do |r|
        if PortabilityIdentity.exists?(public_id: r["ref"]) || (r["draft"] + Array(r["live"])).any? { |node| PortabilityIdentity.exists?(public_id: node["ref"]) }
          conflicts << { "ref" => r["ref"], "kind" => "menu_identity", "resolution" => "This menu or its node identity is already claimed. Reuse the original request key for recovery, or export a separately reviewed selection without the claimed menu. Existing menus are never overwritten." }
        end
      end
      { "inventory" => manifest.slice("content", "revisions", "terms", "media", "menus", "redirects").transform_values(&:length),
        "media_bytes" => manifest["media"].sum { |r| r["display"]["bytes"] + r["thumbnail"]["bytes"] },
        "conflicts" => conflicts, "source_origin" => manifest["site"]["canonical_origin"], "destination_origin" => site.canonical_origin,
        "publication" => "All staged content is private. Source dates and schedule are history only. Activation requires a separate approval.",
        "privacy" => manifest["site"].key?("privacy_first_anonymous") ? "Archive v3 includes anonymous privacy policy. Preserve destination settings unless the separately approved change is intended." : "Legacy archive: destination anonymous privacy policy is preserved.",
        "appearance_compatible" => manifest["appearance"].nil? || ThemeInstallation.exists?(site: site, status: "validated", theme_key: manifest["appearance"]["theme"], version: manifest["appearance"]["version"], digest: manifest["appearance"]["digest"]),
        "plaintext" => true }
    end
    def source_sha(record) = Digest::SHA256.hexdigest(Railpress::SiteArchive.canonical(record))
    def previous_match(site, kind, record)
      ImportItem.joins(:import_batch).where(import_batches: { site_id: site.id }, source_ref: record["ref"], kind: kind, source_sha256: source_sha(record), state: %w[staged activated matched]).order(:id).last
    end
    def approve!(batch:, actor:, session_id:, expected_version:, decisions:)
      Authority.locked(actor: actor, session_id: session_id) do |site, user, session|
        batch.lock!; Authority.version!(batch, expected_version)
        raise Conflict, "This upload is incomplete. Re-upload the verified identical archive, or start a new upload if its bytes were never verified." if batch.report["resume_state"] == "receiving"
        raise Conflict, "Inspect this archive again before approving." unless batch.site_id == site.id && batch.state == "review" && batch.import_items.empty?
        raise Conflict, "Destination changed. Run a fresh dry run and compare." unless batch.baseline_sha256 == destination_digest(site)
        validate_decisions!(batch.manifest, decisions, site)
        batch.update!(actor: user, approval_session_id: session.id, auth_version: user.auth_version, decisions: decisions,
          state: "staging", total: records(batch.manifest).length, progress: 0, failure: nil)
        records(batch.manifest).each do |kind, record|
          batch.import_items.create!(kind: kind, source_ref: record.fetch("ref"), source_sha256: source_sha(record))
        end
        ImportBatch.event!(batch, "stage_approved", { "archive_sha256" => batch.archive_sha256, "normalized_sha256" => batch.normalized_sha256 })
      end
      batch
    end
    def records(manifest)
      %w[authors terms media content revisions menus].flat_map do |collection|
        kind = { "authors"=>"author", "terms"=>"term", "media"=>"media", "content"=>"content", "revisions"=>"revision", "menus"=>"menu" }.fetch(collection)
        manifest.fetch(collection).map { |r| [ kind, r ] }
      end
    end
    def validate_decisions!(manifest, d, site)
      Format.object!(d, %w[authors unassigned content terms media locations settings appearance])
      %w[authors unassigned content terms media].each { |key| raise Format::Invalid, "invalid_decisions" unless d[key].is_a?(Hash) }
      raise Format::Invalid, "settings_decision_required" unless %w[preserve_target apply_nonsensitive].include?(d["settings"])
      raise Format::Invalid, "appearance_decision_required" unless %w[preserve_target stage_compatible].include?(d["appearance"])
      raise Format::Invalid, "location_decision_required" unless %w[preserve_target stage_unassigned].include?(d["locations"])
      author_refs = manifest["authors"].map { |r| r["ref"] }
      raise Format::Invalid, "unknown_or_missing_author_decision" unless d["authors"].keys.sort == author_refs.sort
      d["authors"].each_value { |id| valid_author!(id) }
      raise Conflict, "Distinct portable authors require distinct destination accounts to preserve attribution identity." unless d["authors"].values.uniq == d["authors"].values
      d["authors"].each do |ref, id|
        identity = PortabilityIdentity.find_by(site: site, kind: "author", record_key: id.to_s)
        raise Conflict, "Destination author already has a different portable identity. Choose a separate account or a separately reviewed attribution conversion." if identity && identity.public_id != ref
      end
      manifest["content"].each do |r|
        author = r["working"]["author_ref"]
        valid_author!(author ? d["authors"][author] : d["unassigned"][r["ref"]])
        choice = d["content"].fetch(r["ref"]) { raise Format::Invalid, "content_decision_required" }
        Format.object!(choice, %w[action slug], required: [ "action" ])
        raise Format::Invalid, "invalid_content_decision" unless %w[create match].include?(choice["action"])
        if choice["action"] == "match"
          prior = previous_match(site, "content", r)
          raise Conflict, "No unchanged prior import can be matched." unless prior && Fingerprint.current(prior) == prior.target_sha256
        else
          slug = choice.fetch("slug", r["working"]["slug"])
          probe = r["working"].merge("slug" => slug)
          reference = ->(*) { }
          Format.snapshot!(probe, reference)
          raise Conflict, "Slug or identity is already claimed." if Content.exists?(type: probe["type"], slug_key: Railpress::ContentRoutes.content_key(probe["type"], slug)) || PortabilityIdentity.exists?(public_id: r["ref"])
        end
      end
      manifest["terms"].each do |r|
        choice = d["terms"].fetch(r["ref"]) { raise Format::Invalid, "term_decision_required" }
        Format.object!(choice, %w[action target_id slug], required: [ "action" ])
        raise Format::Invalid, "term_decision" unless %w[create match].include?(choice["action"])
        if choice["action"] == "match"
          target = Term.find_by(id: choice["target_id"])
          raise Conflict, "Taxonomy match must be identical." unless target && target.taxonomy.kind == r["kind"] && target.name == r["name"] && target.slug == r["slug"]
        else
          slug = choice.fetch("slug", r["slug"])
          raise Format::Invalid, "term_slug" unless slug.is_a?(String) && slug.length <= 160 && slug.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
          taxonomy = Taxonomy.find_by(kind: r["kind"])
          raise Conflict, "Taxonomy path or identity is claimed." if (taxonomy && Term.exists?(taxonomy: taxonomy, slug_key: Railpress::ContentRoutes.key(slug))) || PortabilityIdentity.exists?(public_id: r["ref"])
        end
      end
      manifest["media"].each do |r|
        choice = d["media"].fetch(r["ref"]) { raise Format::Invalid, "media_decision_required" }
        Format.object!(choice, %w[action target_id rights_confirmed], required: %w[action rights_confirmed])
        raise Format::Invalid, "current_media_rights_required" unless choice["rights_confirmed"] == true && %w[create match].include?(choice["action"])
        if choice["action"] == "match"
          target = MediaAsset.ready.find_by(id: choice["target_id"])
          raise Conflict, "Media match must have identical metadata and both hashes." unless target && target.sha256 == r["display"]["sha256"] && target.thumbnail_sha256 == r["thumbnail"]["sha256"] && target.attributes.slice(*MediaAsset::METADATA) == r["metadata"]
        else
          raise Conflict, "Media identity already claimed." if PortabilityIdentity.exists?(public_id: r["ref"])
        end
      end
      %w[content terms media].each { |key| raise Format::Invalid, "unknown_resolution" unless d[key].keys.sort == manifest[key].map { |r| r["ref"] }.sort }
      manifest["menus"].each do |menu|
        claimed = PortabilityIdentity.exists?(public_id: menu["ref"]) || (menu["draft"] + Array(menu["live"])).any? { |node| PortabilityIdentity.exists?(public_id: node["ref"]) }
        raise Conflict, "Menu identity is already claimed. Recover its original batch or provide a reviewed selection without that menu; no staging has begun." if claimed
      end
      nil_authors = manifest["content"].select { |r| r["working"]["author_ref"].nil? }.map { |r| r["ref"] }
      raise Format::Invalid, "unassigned_resolution" unless d["unassigned"].keys.sort == nil_authors.sort
      if d["appearance"] == "stage_compatible" && (a = manifest["appearance"])
        raise Conflict, "An identical trusted theme must already be installed." unless ThemeInstallation.exists?(site: site, status: "validated", theme_key: a["theme"], version: a["version"], digest: a["digest"])
      end
    end
    def valid_author!(id)
      raise Format::Invalid, "explicit_existing_author_required" unless id.is_a?(Integer) && User.where(id: id, role: %w[owner administrator editor author]).exists?
    end
    def renew_approval!(batch:, actor:, session_id:, expected_version:)
      Authority.locked(actor: actor, session_id: session_id) do |site, user, session|
        batch.lock!; Authority.version!(batch, expected_version)
        raise Conflict, "This upload is incomplete. Re-upload the verified identical archive, or start a new upload if its bytes were never verified." if batch.report["resume_state"] == "receiving"
        raise Conflict, "Wrong site or state." unless batch.site_id == site.id && %w[needs_approval blocked failed staging activating reversing].include?(batch.state)
        batch.update!(actor: user, approval_session_id: session.id, auth_version: user.auth_version, failure: nil,
          state: batch.report["resume_state"] || (batch.import_items.exists? ? "staging" : "queued"))
        ImportBatch.event!(batch, "approval_renewed")
      end
    end
  end
end
