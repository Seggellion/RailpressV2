# frozen_string_literal: true

module Themes
  module Presentation
    module_function

    def require_capabilities!(manifest, registry: Railpress::Extensions.registry)
      unless capabilities_available?(manifest, registry)
        raise Manager::Protected, "required_extension_unavailable"
      end
    end

    def capabilities_available?(manifest, registry)
      manifest.fetch("requires", {}).all? do |capability, range|
        module_id = capability.split(".").first
        entry = registry.entries[module_id]
        entry && entry.manifest.data.fetch("provides").include?(capability) &&
          Railpress::ThemePackage.version_allowed?(range, entry.version) &&
          ::Extensions::Activation.enabled?(module_id, registry: registry)
      end
    end

    # Module controllers call after access checks and supply only authorized display data.
    # A missing or unavailable slot lets the module render its neutral view.
    def render(site:, module_id:, name:, payload:, actor: nil, authentication_token: nil, credential: nil,
      registry: Railpress::Extensions.registry)
      return unless registry.site == site.install_id && ::Extensions::Activation.enabled?(module_id, registry: registry)
      entry = registry.entries.fetch(module_id)
      return unless entry.manifest.data.fetch("slots").include?("#{module_id}.#{name}")
      pair = Selection.call(site: site, actor: actor, authentication_token: authentication_token, credential: credential)
      return unless pair && pair.installation.site_id == site.id
      bundle = Storage.load(pair.installation)
      return unless bundle.manifest.fetch("slots", {}).key?(name) && capabilities_available?(bundle.manifest, registry)
      presenter = Railpress::ThemeRenderer.presentation_data(name, payload, module_id: module_id)
      Railpress::ThemeRenderer.render_slot(bundle, name, presenter, preview: pair.preview)
    rescue Railpress::ThemePackage::Invalid, Railpress::ThemeRenderer::Invalid, ActionView::Template::Error
      nil
    end
  end
end
