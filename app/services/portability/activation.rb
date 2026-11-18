module Portability
  module Activation
    module_function
    def approve!(batch:, actor:, session_id:, expected_version:, content_refs:, menus:, settings:, appearance:)
      Authority.locked(actor: actor, session_id: session_id) do |site, user, session|
        batch.lock!; Authority.version!(batch, expected_version)
        raise Imports::Conflict, "Only a verified staged batch can be activated." unless batch.site_id == site.id && batch.state == "staged"
        Worker.verify!(batch)
        raise Format::Invalid, "activation_selection" unless content_refs.is_a?(Array) && content_refs.uniq == content_refs && [ menus, settings, appearance ].all? { |v| [ true, false ].include?(v) }
        content_refs.each do |ref|
          record = batch.manifest["content"].find { |r| r["ref"] == ref }
          item = batch.import_items.find_by(kind: "content", source_ref: ref, created_record: true)
          raise Format::Invalid, "private_or_unreviewed_activation_forbidden" unless record && item && record["history"]["state"] == "published" && record["live"] && record["live"]["visibility"] == "public" && record["working"]["portable_metadata"].fetch("review", {}).blank?
        end
        raise Format::Invalid, "settings_not_approved" if settings && batch.decisions["settings"] != "apply_nonsensitive"
        raise Format::Invalid, "appearance_not_staged" if appearance && !batch.report["overlay_id"]
        if appearance
          overlay = ThemeOverlay.find(batch.report["overlay_id"])
          preview = ThemePreview.where(actor: user, theme_overlay: overlay, session_digest: session.token_digest, auth_version: user.auth_version).any?(&:deadline_valid?)
          raise Themes::Manager::Protected, "owner_preview_required" unless preview
        end
        batch.update!(actor: user, approval_session_id: session.id, auth_version: user.auth_version, state: "activating",
          report: batch.report.merge("activation" => { "content_refs" => content_refs, "menus" => menus, "settings" => settings, "appearance" => appearance }, "activation_baseline" => Imports.destination_digest(site), "resume_state" => "activating"))
        ImportBatch.event!(batch, "activation_approved", { "content" => content_refs.length, "menus" => menus, "settings" => settings, "appearance" => appearance })
      end
    end
    def perform!(batch, fault: nil)
      # Activation is one bounded SQL transaction. Files were already validated
      # during staging. It is never a background interpretation of source status.
      Authority.record_locked(batch) do |site, actor, session|
        Context.require!(batch); Worker.verify!(batch)
        raise Imports::Conflict, "Destination changed after activation review." unless Imports.destination_digest(site) == batch.report.fetch("activation_baseline")
        policy = batch.report.fetch("activation")
        raise Format::Invalid, "menu_locations_not_approved" if policy["menus"] && batch.decisions["locations"] != "stage_unassigned" && batch.manifest["menus"].any? { |m| m["locations"].any? }
        policy.fetch("content_refs").each do |ref|
          record = batch.manifest["content"].find { |r| r["ref"] == ref }
          item = batch.import_items.find_by!(kind: "content", source_ref: ref, created_record: true)
          content = Content.lock.find(item.target_id)
          live = Stage.snapshot(batch, record.fetch("live"), ref).merge("visibility" => "public")
          live["slug"] = batch.decisions["content"].fetch(ref).fetch("slug", live.fetch("slug"))
          # Source homepage flags are historical data, not settings authority.
          live["home_page"] = policy["settings"] && batch.manifest["site"]["homepage_ref"] == ref
          Editorial::PortableContent.apply_working!(actor: actor, content: content, attributes: live, author_id: live.fetch("author_id"))
          Editorial::Workflow.update!(actor: actor, content: content, expected_version: content.lock_version, event: "publish")
          working = Stage.snapshot(batch, record.fetch("working"), ref)
          working["slug"] = live["slug"]
          working["home_page"] = false unless policy["settings"]
          # Keep an unpublished working edit separate from the approved live snapshot.
          Editorial::PortableContent.apply_working!(actor: actor, content: content, attributes: working, author_id: working.fetch("author_id"))
          item.update!(state: "activated", target_sha256: Fingerprint.current(item))
          fault&.call("activated_content", item)
        end
        if policy["menus"]
          batch.manifest["menus"].each do |source|
            next unless source["live"]
            item = batch.import_items.find_by!(kind: "menu", source_ref: source["ref"])
            menu = Menu.lock.find(item.target_id)
            mutate = lambda do |operation, payload|
              menu = Navigation::Mutation.call(actor: actor, menu: menu, operation: operation, payload: payload, expected_version: menu.lock_version, expected_state: Navigation::Mutation.generation(site))
            end
            mutate.call("import_tree", { "tree" => Stage.tree(batch, menu, source["live"]) })
            # Explicit activation may claim only empty or this batch's locations.
            locations = source["locations"].select { |l| l["live"] }.map { |l| "#{l['theme']}:#{l['key']}" }
            locations.each do |location|
              theme, key = location.split(":", 2); row = MenuLocation.lock.find_by(site: site, theme_key: theme, key: key)
              raise Imports::Conflict, "A target menu location is already claimed." if row && [ row.draft_menu_id, row.published_menu_id ].compact.any? { |id| id != menu.id }
            end
            mutate.call("assign", { "locations" => locations })
            mutate.call("publish", {})
            mutate.call("import_tree", { "tree" => Stage.tree(batch, menu, source["draft"]) })
            draft_locations = source["locations"].select { |l| l["draft"] }.map { |l| "#{l['theme']}:#{l['key']}" }
            mutate.call("assign", { "locations" => draft_locations })
            item.update!(state: "activated", target_sha256: Fingerprint.current(item), details: item.details.merge("locations" => MenuLocation.where(site: site).where("draft_menu_id = ? OR published_menu_id = ?", menu.id, menu.id).map { |l| l.attributes.except("created_at", "updated_at") }))
          end
        end
        batch.manifest["redirects"].each do |source|
          next unless policy["content_refs"].include?(source["content_ref"])
          id = Stage.target(batch, "content", source["content_ref"])
          raise Imports::Conflict, "Redirect path is already claimed." if Redirect.exists?(source_digest: Digest::SHA256.hexdigest(source["path"]))
          redirect = Redirect.create!(source_path: source["path"], target_content_id: id)
          batch.import_items.create!(kind: "redirect", source_ref: "redirect:#{redirect.source_digest}", state: "activated", target_id: redirect.id, created_record: true, source_sha256: Imports.source_sha(source), details: { "source_record" => source })
        end
        if policy["settings"]
          before = site.attributes.slice("title", "tagline", "locale", "timezone", "indexing_enabled", "home_mode", "homepage_content_id", "organization_name", "privacy_first_anonymous")
          settings = batch.manifest["site"].slice("title", "tagline", "locale", "timezone", "indexing_enabled", "home_mode", "organization_name", "privacy_first_anonymous")
          homepage = batch.manifest["site"]["homepage_ref"]
          raise Imports::Conflict, "Homepage must be explicitly activated." if homepage && !policy["content_refs"].include?(homepage)
          settings["homepage_content_id"] = homepage && Stage.target(batch, "content", homepage)
          # canonical_origin is intentionally destination-owned; operator settings never enter this writer.
          site.update!(settings)
          batch.report = batch.report.merge("settings_before" => before, "settings_after" => settings)
        end
        if policy["appearance"]
          overlay = ThemeOverlay.find(batch.report.fetch("overlay_id")); package = overlay.theme_installation
          raise Themes::Manager::Protected, "owner_preview_required" unless ThemePreview.where(actor: actor, theme_overlay: overlay, session_digest: session.token_digest, auth_version: actor.auth_version).any?(&:deadline_valid?)
          Themes::Manager.activate!(actor: actor, installation: package, overlay: overlay, version: ThemeState.find_by(site: site)&.lock_version || 0)
          batch.report = batch.report.merge("appearance_activated" => true)
        end
        batch.update!(state: "complete", lease: {}, lease_token: nil, report: batch.report.merge("activation_verified" => true))
        Worker.release!(batch, site)
        ImportBatch.event!(batch, "activation_verified")
      end
    end
  end
end
