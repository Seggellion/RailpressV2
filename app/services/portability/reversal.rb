module Portability
  module Reversal
    module_function
    def reasons(batch)
      reasons = []
      reasons << "No complete archive was received. Recover the verified upload or start a new upload; no content was staged." if batch.report["resume_state"] == "receiving"
      items = batch.import_items.to_a
      begin
        plan = Imports.records(batch.manifest)
        core = items.select { |i| %w[author term media content revision menu].include?(i.kind) }
        raise Format::Invalid, "journal_inventory" unless plan.length == core.length
        plan.each do |kind, record|
          item = core.find { |i| i.kind == kind && i.source_ref == record["ref"] }
          raise Format::Invalid, "journal_source" unless item && item.source_sha256 == Imports.source_sha(record)
          next unless item.target_id && item.state != "reversed"
          created = case kind
          when "author" then false
          when "term", "media", "content" then batch.decisions.fetch({ "term"=>"terms", "media"=>"media", "content"=>"content" }.fetch(kind)).fetch(record["ref"]).fetch("action") == "create"
          when "revision" then batch.decisions.fetch("content").fetch(record.fetch("content_ref")).fetch("action") == "create"
          when "menu" then true
          end
          raise Format::Invalid, "journal_created_match_provenance" unless item.created_record == created
          if created
            raise Format::Invalid, "journal_introduced_identity" unless PortabilityIdentity.exists?(site: batch.site, kind: kind, record_key: item.target_id.to_s, public_id: record["ref"])
          end
        end
      rescue KeyError, TypeError, Format::Invalid
        reasons << "Journal integrity or created-versus-matched provenance failed. Reversal cannot infer ownership."
      end
      created = items.select(&:created_record)
      content_ids = created.select { |i| i.kind == "content" }.map(&:target_id).compact
      revision_ids = ContentRevision.where(content_id: content_ids).pluck(:id)
      menu_ids = created.select { |i| i.kind == "menu" }.map(&:target_id).compact
      created.each do |item|
        next if item.state == "reversed" || !item.target_id
        if %w[content term media revision menu].include?(item.kind) && Fingerprint.current(item) != item.target_sha256
          reasons << "#{item.kind} #{item.source_ref} was edited or removed after import."
        end
        if ImportItem.where(kind: item.kind, target_id: item.target_id).where.not(import_batch_id: batch.id).where.not(state: "reversed").exists?
          reasons << "#{item.kind} #{item.source_ref} is claimed by another import."
        end
        case item.kind
        when "content"
          reasons << "Content #{item.source_ref} has a later preview claim." if ContentPreview.exists?(content_id: item.target_id)
          if MenuItem.where(content_id: item.target_id).where.not(menu_id: menu_ids).exists? || Redirect.where(target_content_id: item.target_id).where.not(id: created.select { |i| i.kind == "redirect" }.map(&:target_id)).exists?
            reasons << "Content #{item.source_ref} has unrelated navigation or redirect claims."
          end
          # Published trees can retain references absent from the current editor.
          Menu.where.not(id: menu_ids).where.not(published_revision_id: nil).each do |menu|
            reasons << "Content #{item.source_ref} is retained by a published menu." if menu.published_revision.snapshot.fetch("tree").any? { |r| r["content_id"] == item.target_id }
          end
          reasons << "Content #{item.source_ref} has a destination news review." if OfficialNewsReview.exists?(content_id: item.target_id)
          MenuRevision.where.not(menu_id: menu_ids).each do |revision|
            reasons << "Content #{item.source_ref} is retained by unrelated menu history." if Array(revision.snapshot["tree"]).any? { |r| r["content_id"] == item.target_id }
          end
        when "term"
          reasons << "Taxonomy #{item.source_ref} is used by unrelated content." if ContentTerm.where(term_id: item.target_id).where.not(content_id: content_ids).exists?
          reasons << "Taxonomy #{item.source_ref} is used by unrelated menus." if MenuItem.where(term_id: item.target_id).where.not(menu_id: menu_ids).exists?
        when "media"
          MediaReference.where(media_asset_id: item.target_id).each do |reference|
            owned = (reference.content_id && content_ids.include?(reference.content_id)) || (reference.content_revision_id && revision_ids.include?(reference.content_revision_id)) || (reference.theme_overlay_id && reference.theme_overlay_id == batch.report["overlay_id"])
            reasons << "Media #{item.source_ref} has an unrelated or preview reference." unless owned
          end
        when "menu"
          if item.details["locations"]
            current = MenuLocation.where("draft_menu_id = ? OR published_menu_id = ?", item.target_id, item.target_id).map { |l| l.attributes.except("created_at", "updated_at") }
            reasons << "Menu assignments changed after activation." unless current == item.details["locations"]
          end
        when "redirect"
          row = Redirect.find_by(id: item.target_id); source = item.details["source_record"]
          reasons << "Redirect changed after activation." unless row && row.source_path == source["path"] && row.target_content_id == Stage.target(batch, "content", source["content_ref"])
        end
      end
      if batch.report["settings_after"]
        reasons << "Site settings changed after activation." unless batch.site.attributes.slice(*batch.report["settings_after"].keys) == batch.report["settings_after"]
      end
      if batch.report["overlay_id"]
        id = batch.report["overlay_id"]
        reasons << "Imported appearance is active, retained or previewed; recover the theme separately first." if ThemeState.where("active_overlay_id = ? OR previous_overlay_id = ?", id, id).exists? || ThemePreview.where(theme_overlay_id: id).exists?
      end
      reasons.uniq
    end
    def approve!(batch:, actor:, session_id:, expected_version:)
      Authority.locked(actor: actor, session_id: session_id) do |site, user, session|
        batch.lock!; Authority.version!(batch, expected_version)
        raise Imports::Conflict, "Batch cannot be reversed in this state." unless batch.site_id == site.id && %w[staged complete blocked failed needs_approval].include?(batch.state)
        raise Imports::Conflict, "An active worker must finish or its claim must expire." if batch.lease_token && Worker.lease_valid?(batch)
        issues = reasons(batch)
        raise Imports::Conflict, issues.join(" ") if issues.any?
        batch.update!(actor: user, approval_session_id: session.id, auth_version: user.auth_version, state: "reversing", report: batch.report.merge("resume_state" => "reversing"))
        ImportBatch.event!(batch, "reversal_approved")
      end
    end
    def perform!(batch, fault: nil)
      cleanup = []
      Authority.record_locked(batch) do |site, _actor, _session|
        Context.require!(batch)
        issues = reasons(batch); raise Imports::Conflict, issues.join(" ") if issues.any?
        items = batch.import_items.order(:id).lock.to_a
        items.select { |i| i.kind == "media" && i.details["media_upload_id"] }.each { |item| Worker.reconcile_upload!(item) }
        content_ids = items.select { |i| i.kind == "content" && i.created_record }.map(&:target_id).compact
        menu_ids = items.select { |i| i.kind == "menu" && i.created_record }.map(&:target_id).compact
        if batch.report["settings_before"]
          site.update!(batch.report["settings_before"])
        end
        site.update!(homepage_content_id: nil) if content_ids.include?(site.homepage_content_id)
        items.select { |i| i.kind == "redirect" && i.created_record }.each { |i| Redirect.where(id: i.target_id).delete_all }
        ActiveSupport::IsolatedExecutionState[:navigation_mutation] = true
        MenuLocation.where(draft_menu_id: menu_ids).update_all(draft_menu_id: nil)
        MenuLocation.where(published_menu_id: menu_ids).update_all(published_menu_id: nil)
        Menu.where(id: menu_ids).update_all(published_revision_id: nil)
        Menu.where(id: menu_ids).each { |m| Navigation::Tree.ordered(m.tree).reverse_each { |row| MenuItem.where(menu: m, key: row["key"]).delete_all } }
        MenuRevision.where(menu_id: menu_ids).delete_all; Menu.where(id: menu_ids).delete_all
        ActiveSupport::IsolatedExecutionState.delete(:navigation_mutation)
        content_previews = ContentPreview.where(content_id: content_ids).pluck(:id)
        revision_ids = ContentRevision.where(content_id: content_ids).pluck(:id)
        MediaReference.where(content_preview_id: content_previews).delete_all
        MediaReference.where(content_revision_id: revision_ids).delete_all
        MediaReference.where(content_id: content_ids).delete_all
        ContentPreview.where(content_id: content_ids).delete_all
        ContentRevision.where(content_id: content_ids).delete_all; ContentTerm.where(content_id: content_ids).delete_all
        DashboardDraftSubmission.where(content_id: content_ids).delete_all
        Content.where(id: content_ids).each(&:destroy!)
        if (overlay_id = batch.report["overlay_id"])
          MediaReference.where(theme_overlay_id: overlay_id).delete_all
          ThemeOverlay.where(id: overlay_id).delete_all
        end
        items.select { |i| i.kind == "term" && i.created_record && i.target_id }.each { |i| Term.find(i.target_id).destroy! }
        items.select { |i| i.kind == "media" && i.created_record && i.target_id }.each do |item|
          asset = MediaAsset.find(item.target_id)
          blobs = [ asset.blob, asset.thumbnail_blob ]
          item.update!(details: item.details.merge("cleanup_keys" => blobs.map(&:key), "cleanup_blob_ids" => blobs.map(&:id)))
          MediaAsset.where(id: asset.id).delete_all
          cleanup << item.id
        end
        items.each do |item|
          if item.created_record
            PortabilityIdentity.where(site: site, kind: item.kind, record_key: item.target_id.to_s).delete_all
            PortabilityIdentity.where(site: site, kind: "menu_node").where("record_key LIKE ?", "#{item.target_id}:%").delete_all if item.kind == "menu"
          end
          item.update!(state: "reversed")
        end
        fault&.call("reversal_before_commit", batch)
        batch.update!(state: "reversed", lease: {}, lease_token: nil, report: batch.report.merge("reversal_verified" => true, "object_cleanup" => "pending"))
        Worker.release!(batch, site)
        ImportBatch.event!(batch, "records_reversed", { "created_records" => items.count(&:created_record), "matched_records_preserved" => items.count { |i| !i.created_record } })
        Seo::Invalidation.bump!
      ensure
        ActiveSupport::IsolatedExecutionState.delete(:navigation_mutation)
      end
      cleanup!(batch)
    end
    def request_cleanup!(batch:, actor:, session_id:, expected_version:)
      Authority.locked(actor: actor, session_id: session_id) do |site, user, session|
        batch.lock!; Authority.version!(batch, expected_version)
        raise Imports::Conflict, "Cleanup requires a reversed batch on this site." unless batch.site_id == site.id && batch.state == "reversed"
        # Only an explicit fresh Owner action may replace an expired approval.
        batch.update!(actor: user, approval_session_id: session.id, auth_version: user.auth_version)
        ImportBatch.event!(batch, "cleanup_approved")
      end
      cleanup!(batch)
    end
    def cleanup!(batch)
      # Durable keys permit safe retry after SQL commit/process death. Neither
      # archive filenames nor arbitrary object keys are ever used as delete paths.
      Authority.record_locked(batch) do
        raise Imports::Conflict, "Cleanup requires a reversed batch." unless batch.state == "reversed"
        batch.import_items.where(kind: "media", created_record: true, state: "reversed").each do |item|
          keys = item.details["cleanup_keys"] || []
          ids = item.details["cleanup_blob_ids"] || []
          unless keys.empty? && ids.empty?
            attempt = MediaUpload.find_by(id: item.details["media_upload_id"], state: "accepted")
            raise Format::Invalid, "cleanup_journal_integrity" unless attempt && keys.length == 2 && ids.length == 2 && attempt.storage_keys == keys
            ids.zip(keys).each do |id, key|
              blob = ActiveStorage::Blob.find_by(id: id)
              raise Format::Invalid, "cleanup_blob_identity" if blob && blob.key != key
              raise Format::Invalid, "cleanup_key_identity" if ActiveStorage::Blob.where(key: key).where.not(id: id).exists?
            end
          end
          raise Imports::Conflict, "A cleanup object was claimed." if MediaAsset.where(blob_id: ids).or(MediaAsset.where(thumbnail_blob_id: ids)).exists? || ActiveStorage::Attachment.where(blob_id: ids).exists?
          keys.each { |key| MediaLibrary::Storage.delete_key!(key) }
          ActiveStorage::Blob.where(id: ids, key: keys).delete_all
          item.update!(details: item.details.merge("cleanup_keys" => [], "cleanup_blob_ids" => []))
        end
        batch.update!(report: batch.report.merge("object_cleanup" => "complete"))
        ImportBatch.event!(batch, "objects_cleaned")
      end
    end
  end
end
