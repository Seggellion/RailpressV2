# frozen_string_literal: true

module Releases
  module Combined
    class Conflict < StandardError; end
    PROTOCOL = "railpress.combined.v1"
    module_function
    def capable?
      status = HostStatus.read
      status && status["verified"] && status["fresh"] && status.dig("statement", "combined_protocol") == PROTOCOL &&
        status.dig("statement", "combined_ready") == true && status.dig("statement", "restore_drill_completed") == true &&
        status.dig("statement", "backup_verified") == true &&
        status.dig("statement", "snapshot_id").is_a?(String) && HostStatus.operations.include?("promote")
    end
    def key(id) = "combined-#{id}"
    def selection(request) = Catalog.payload(key(request.request_key))
    def theme_identity(package) = package && { "id" => package.theme_key, "version" => package.version, "digest" => package.digest }
    def choices(manifest)
      state = ThemeState.find_by(site: Site.find_by!(singleton_key: 1))
      return [] unless state&.active_installation
      manifest["compatibility"]["themes"].filter_map do |identity|
        next unless identity["id"] == state.active_installation.theme_key &&
          Railpress::Releases.compare_versions(identity["version"], state.active_installation.version).positive?
        ThemeInstallation.find_by(site: state.site, theme_key: identity["id"], version: identity["version"], digest: identity["digest"], status: "validated")
      end
    end
    def submit!(actor:, release_id:, request_id:, theme_id: nil)
      raise Identity::Capabilities::Denied unless actor&.owner?
      raise Conflict, "Host/backup/time adapter is not qualified for one-button updates." unless capable?
      item = Catalog.verified_items.find { |candidate| candidate["release_id"] == release_id }
      raise Conflict, "Reload verified release metadata before selecting an update." unless item
      Railpress::Releases::Manifest.compatible!(item["manifest"], Context.current)
      Site.transaction do
        site = Site.find_by!(singleton_key: 1); site.lock!; actor.lock!
        Identity::Capabilities.require!(actor, :inspect_updates)
        existing = ReleaseRequest.find_by(request_key: request_id)
        if existing
          prior = selection(existing)
          raise Conflict, "Update selection changed; submit a new request." unless existing.actor_id == actor.id && existing.actor_auth_version == actor.auth_version &&
            existing.operation == "promote" && existing.release_digest == release_id && prior["format"] == PROTOCOL && prior["selected_theme_id"].to_s == theme_id.to_s
          return existing
        end
        state = ThemeState.find_by(site: site)
        raise Conflict, "Select and validate an active theme before combined updates." unless state&.active_installation
        state.lock!
        target = theme_id.present? ? choices(item["manifest"]).find { |package| package.id.to_s == theme_id.to_s } : nil
        raise Conflict, "Selected theme is incompatible or no longer available." if theme_id.present? && !target
        overlay = target&.theme_overlays&.order(number: :desc)&.first
        if target
          Themes::Storage.load(target)
          raise Conflict, "Preview the selected compatible theme before updating." unless overlay && ThemePreview.where(actor: actor, theme_installation: target, theme_overlay: overlay, auth_version: actor.auth_version).any?(&:deadline_valid?)
        end
        request = Requests.submit!(actor: actor, operation: "promote", release_id: release_id, request_id: request_id)
        plan = { "format" => PROTOCOL, "request_id" => request.request_key, "release_id" => release_id, "version" => item["version"],
          "actor_id" => actor.id, "auth_version" => actor.auth_version, "expected_theme_revision" => state.lock_version,
          "old_theme_id" => state.active_installation_id, "old_overlay_id" => state.active_overlay_id,
          "selected_theme_id" => target&.id, "selected_overlay_id" => overlay&.id, "selected_theme" => theme_identity(target),
          "manifest_sha256" => release_id }
        Catalog.save!(key(request.request_key), plan)
        request
      end
    end
    def validate!(request, plan, theme_unchanged: true)
      raise Conflict, "Update plan identity changed." unless request.operation == "promote" && plan["format"] == PROTOCOL && plan["request_id"] == request.request_key && plan["release_id"] == request.release_digest && plan["actor_id"] == request.actor_id
      actor = User.find(request.actor_id)
      raise Identity::Capabilities::Denied unless actor.owner? && actor.auth_version == request.actor_auth_version && actor.auth_version == plan["auth_version"]
      if theme_unchanged
        state = ThemeState.find_by!(site_id: request.site_id)
        raise Conflict, "Theme or customization changed after approval." unless state.lock_version == plan["expected_theme_revision"] &&
          state.active_installation_id == plan["old_theme_id"] && state.active_overlay_id == plan["old_overlay_id"]
      end
      actor
    end
    def result(request)
      plan = selection(request); envelope = plan["result"]
      return nil unless envelope
      statement = envelope.fetch("statement"); trust = Requests.roots
      id = Railpress::Releases.signature!(Railpress::Releases.canonical(statement), envelope.fetch("signature"), trust.roots, purpose: "status")
      raise Conflict if trust.revoked.include?(id)
      raise Conflict unless statement["format"] == PROTOCOL && statement["request_id"] == request.request_key && statement["release_id"] == request.release_digest &&
        statement["selection_sha256"] == Digest::SHA256.hexdigest(Railpress::Releases.canonical(plan.except("result"))) &&
        %w[COMPLETE FAILED_STAGED CORE_UPDATE_FAILED CORE_UPDATED_THEME_REVIEW_REQUIRED].include?(statement["state"])
      statement
    rescue StandardError
      { "state" => "UNVERIFIED", "detail" => "Combined update receipt could not be verified." }
    end
  end
end
