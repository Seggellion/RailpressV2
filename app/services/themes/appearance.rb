require "railpress/releases"

module Themes
  # Additive API1 capability. Older packages/overlays retain their light semantics.
  module Appearance
    MODES = %w[light dark system].freeze
    module_function
    def supported?(manifest)
      manifest["id"] == "dusk" && manifest.dig("options", "appearance_modes") == %w[system light dark]
    end
    def mode(manifest, options)
      return unless supported?(manifest)
      value = options.fetch("appearance_mode", "light")
      raise ArgumentError, "invalid_appearance_mode" unless MODES.include?(value)
      value
    end
    def inherited_attributes(state, installation, predecessor_id: nil)
      unless supported?(installation.manifest)
        raise Manager::Conflict, "overlay_predecessor_not_supported" if predecessor_id
        return {}
      end
      previous = ThemeInstallation.where(site_id: state.site_id, theme_key: "dusk", status: "validated").order(:id).limit(33).to_a
      raise Manager::Conflict, "dusk_overlay_inventory_requires_review" if previous.length > 32
      older_ids = previous.select { |package| Railpress::Releases.compare_versions(package.version, installation.version).negative? }.map(&:id)
      eligible = ThemeOverlay.where(theme_installation_id: older_ids)
      source = if predecessor_id
        eligible.find_by(id: predecessor_id) || raise(Manager::Conflict, "invalid_dusk_overlay_predecessor")
      else
        [ state.active_overlay, state.previous_overlay ].compact.find { |overlay| older_ids.include?(overlay.theme_installation_id) } ||
          sole_inactive_predecessor(eligible)
      end
      return {} unless source
      Storage.load(source.theme_installation)
      source.options.merge("appearance_mode" => source.options.fetch("appearance_mode", "light")).merge(
        source.media_details.to_h.to_h { |kind, detail| [ "#{kind}_id", detail.fetch("asset_id") ] })
    end
    def sole_inactive_predecessor(scope)
      choices = scope.order(:id).limit(2).to_a
      raise Manager::Conflict, "choose_dusk_overlay_predecessor" if choices.length > 1
      choices.first
    end
    def map_upload(state, installation)
      source = state.active_overlay
      previous = source&.theme_installation
      return [ {}, {} ] unless previous&.theme_key == installation.theme_key &&
        Railpress::Releases.compare_versions(previous.version, installation.version).negative?
      Storage.load(previous)
      options = source.options.slice("footer", "brand_label", "header_style", "footer_style")
      reset = []
      { "palette" => "palettes", "font" => "fonts", "layout" => "layouts", "home_pattern" => "home_patterns" }.each do |field, choices|
        old = source.options[field]
        if installation.manifest.fetch("options").fetch(choices).include?(old)
          options[field] = old
        else
          reset << field
        end
      end
      source.media_details.each do |name, detail|
        options["#{name}_id"] = detail.fetch("asset_id")
      end
      [ options, { "from_overlay" => source.id, "mapped" => options.keys.sort, "reset" => reset.sort } ]
    end
  end
end
