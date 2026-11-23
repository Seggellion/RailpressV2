module Themes
  module Manager
    class Conflict < StandardError; end
    class Protected < StandardError; end
    module_function
    def locked(actor)
      Site.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        actor.lock!
        Identity::Capabilities.require!(actor, :manage_themes)
        state = ThemeState.find_or_create_by!(site: site)
        state.lock!
        yield site, state
      end
    end
    def stage!(actor:, directory:, predecessor_overlay_id: nil, expected_digest: nil)
      Identity::Capabilities.require!(actor, :manage_themes)
      bundle = Railpress::ThemePackage.load(directory, trusted_keys: Storage.trusted_keys)
      raise Conflict, "theme_candidate_changed" if expected_digest && bundle.digest != expected_digest
      path = Storage.install(bundle)
      report = Smoke.call(path)
      locked(actor) do |site, state|
        if bundle.manifest["id"] == "dusk" && ThemeInstallation.where(site: site, theme_key: "dusk", version: bundle.manifest["version"]).where.not(digest: bundle.digest).exists?
          raise Conflict, "dusk_version_digest_conflict"
        end
        package = ThemeInstallation.find_or_create_by!(site: site, theme_key: bundle.manifest["id"], version: bundle.manifest["version"], digest: bundle.digest) do |record|
          record.manifest = bundle.manifest
          record.smoke_report = report
        end
        raise Protected, "removed_identity" unless package.status == "validated"
        unless package.theme_overlays.exists?
          initial = Appearance.inherited_attributes(state, package, predecessor_id: predecessor_overlay_id)
          initial = initial.merge("artwork_style" => "none") if bundle.manifest["options"].key?("artwork_styles") && initial.any? && !initial.key?("artwork_style")
          overlay!(actor: actor, installation: package, attributes: initial)
        end
        Activity::Recorder.record!(actor: actor, action: "theme.stage", subject: package, details: { version: package.version, digest: package.digest })
        package
      end
    end
    def overlay!(actor:, installation:, attributes:)
      locked(actor) do |_site, _state|
        installation.lock!
        bundle = Storage.load(installation)
        values = attributes.to_h.stringify_keys
        allowed = %w[palette font layout footer home_pattern logo_id favicon_id brand_label header_style footer_style]
        allowed << "artwork_style" if bundle.manifest["options"].key?("artwork_styles")
        allowed << "appearance_mode" if Appearance.supported?(bundle.manifest)
        raise ArgumentError, "unknown_overlay_field" unless (values.keys - allowed).empty?
        options = {}
        if bundle.manifest["options"].key?("artwork_styles")
          options["artwork_style"] = values.fetch("artwork_style", "editorial")
          raise ArgumentError, "invalid_artwork_style" unless bundle.manifest["options"]["artwork_styles"].include?(options["artwork_style"])
        end
        if Appearance.supported?(bundle.manifest)
          options["appearance_mode"] = values.fetch("appearance_mode", "system")
          Appearance.mode(bundle.manifest, options)
        end
        { "palette" => "palettes", "font" => "fonts", "layout" => "layouts", "home_pattern" => "home_patterns" }.each do |key, choices|
          options[key] = values.fetch(key, bundle.manifest["options"][choices].first)
          raise ArgumentError, "invalid_option" unless bundle.manifest["options"][choices].include?(options[key])
        end
        options["footer"] = values.fetch("footer", "").to_s
        raise ArgumentError, "footer_bounds" if options["footer"].length > 500 || options["footer"].match?(/[<>\x00]/)
        options["brand_label"] = values.fetch("brand_label", "").to_s
        raise ArgumentError, "brand_bounds" if options["brand_label"].length > 100 || !options["brand_label"].valid_encoding? || options["brand_label"].match?(/[<>\x00-\x1f]/)
        { "header_style" => %w[standard centered], "footer_style" => %w[standard compact] }.each do |key, choices|
          options[key] = values.fetch(key, choices.first)
          raise ArgumentError, "invalid_option" unless choices.include?(options[key])
        end
        media = {}; assets = []
        %w[logo favicon].each do |key|
          id = values["#{key}_id"]
          next if id.blank?
          asset = MediaAsset.lock.find(id)
          MediaLibrary::Policy.read!(actor, asset)
          raise ArgumentError, "theme_image_required" unless asset.state == "ready" && asset.blob&.content_type == "image/png" && asset.width <= 1024 && asset.height <= 1024 && asset.alt_text.present?
          media[key] = { "asset_id" => asset.id, "alt" => asset.alt_text }
          assets << asset
        end
        overlay = ThemeOverlay.create!(theme_installation: installation, author: actor, number: installation.theme_overlays.maximum(:number).to_i + 1, options: options, media_details: media)
        assets.uniq.each { |asset| MediaReference.create!(theme_overlay: overlay, media_asset: asset, stage: "theme") }
        Activity::Recorder.record!(actor: actor, action: "theme.overlay", subject: overlay, details: { revision: overlay.number })
        overlay
      end
    end
    def activate!(actor:, installation:, overlay:, version:, require_preview: true)
      locked(actor) do |_site, state|
        raise Conflict, "theme_state_changed" unless version.to_s == state.lock_version.to_s
        installation.lock!
        raise ArgumentError, "wrong_site" unless installation.site_id == state.site_id
        raise ArgumentError, "overlay_package" unless overlay.theme_installation_id == installation.id
        Storage.load(installation)
        if require_preview && !ThemePreview.where(actor: actor, theme_installation: installation, theme_overlay: overlay, auth_version: actor.auth_version).order(:id).any?(&:deadline_valid?)
          raise Protected, "owner_preview_required"
        end
        raise Protected, "smoke_required" unless installation.smoke_report["digest"] == installation.digest
        state.update!(previous_installation: state.active_installation, previous_overlay: state.active_overlay, active_installation: installation, active_overlay: overlay)
        installation.update!(ever_active_at: installation.ever_active_at || Time.current)
        Activity::Recorder.record!(actor: actor, action: "theme.activate", subject: installation, details: { revision: overlay.number })
        state
      end
    end
    def revert!(actor:, version:)
      locked(actor) do |_site, state|
        raise Protected, "no_previous_package" unless state.previous_installation && state.previous_overlay
        result = activate!(actor: actor, installation: state.previous_installation, overlay: state.previous_overlay, version: version, require_preview: false)
        Activity::Recorder.record!(actor: actor, action: "theme.revert", subject: result.active_installation)
        result
      end
    end
    def preview!(actor:, installation:, overlay:, authentication_token:)
      locked(actor) do |_site, _state|
        raise ArgumentError, "valid_session_required" unless UserSession.resolve(authentication_token)&.user_id == actor.id && overlay.theme_installation_id == installation.id
        Storage.load(installation)
        token = SecureRandom.hex(32)
        ThemePreview.where(actor: actor, session_digest: Digest::SHA256.hexdigest(authentication_token)).delete_all
        ThemePreview.create!(actor: actor, theme_installation: installation, theme_overlay: overlay, token_digest: Digest::SHA256.hexdigest(token), session_digest: Digest::SHA256.hexdigest(authentication_token), auth_version: actor.auth_version, expires_at: 10.minutes.from_now)
        Activity::Recorder.record!(actor: actor, action: "theme.preview", subject: installation, details: { revision: overlay.number })
        { "token" => token }
      end
    end
    def remove!(actor:, installation:)
      locked(actor) do |_site, state|
        installation.lock!
        raise Protected, "default_active_retained_or_preview" if installation.theme_key == "dusk" || [ state.active_installation_id, state.previous_installation_id ].include?(installation.id) || ThemePreview.where(theme_installation: installation).order(:id).any?(&:deadline_valid?)
        installation.update!(status: "removed")
        Activity::Recorder.record!(actor: actor, action: "theme.remove", subject: installation)
      end
    end
  end
end
