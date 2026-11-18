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
    def inherited_attributes(state, installation)
      return {} unless supported?(installation.manifest)
      source = [ state.active_overlay, state.previous_overlay ].compact.find do |overlay|
        package = overlay.theme_installation
        package.theme_key == "dusk" && Gem::Version.new(package.version) < Gem::Version.new(installation.version)
      end
      return {} unless source
      source.options.merge("appearance_mode" => source.options.fetch("appearance_mode", "light")).merge(
        source.media_details.to_h.to_h { |kind, detail| [ "#{kind}_id", detail.fetch("asset_id") ] })
    end
  end
end
