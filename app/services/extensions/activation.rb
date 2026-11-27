# frozen_string_literal: true

module Extensions
  module Activation
    Invalid = Railpress::Extensions::Invalid
    module_function

    def enabled?(module_id, registry: Railpress::Extensions.registry)
      return false unless registry.site && registry.entries.key?(module_id)
      ActiveRecord::Base.uncached do
        site = Site.find_by(singleton_key: 1, install_id: registry.site)
        next false unless site
        records = ExtensionInstallation.where(site: site, package_state: "installed", enabled: true).index_by(&:module_id)
        active_selection?(module_id, records, registry)
      end
    end

    def change!(actor:, module_id:, generation:, enabled:, registry: Railpress::Extensions.registry)
      Railpress::Extensions.id!(module_id)
      Railpress::Extensions.generation!(generation)
      raise Invalid, "extension_activation_value" unless [ true, false ].include?(enabled)
      Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        fresh = Requests.locked_owner!(actor.id, actor.auth_version)
        installation = ExtensionInstallation.lock.find_by!(site: site, module_id: module_id, package_state: "installed")
        raise Invalid, "extension_activation_stale" unless installation.activation_generation == generation
        return installation if installation.enabled == enabled

        if enabled
          raise Invalid, "extension_engine_not_running" unless same_selection?(installation, registry)
          raise Invalid, "extension_candidate_withdrawal_required" unless withdrawal_compatible?(module_id, registry)
          raise Invalid, "extension_route_collision" if registry.entries.fetch(module_id).manifest.routes["public"] && collision?(module_id)
          records = ExtensionInstallation.where(site: site, package_state: "installed", enabled: true).index_by(&:module_id)
          unless registry.entries.fetch(module_id).manifest.dependencies.keys.all? { |id| active_selection?(id, records, registry) }
            raise Invalid, "extension_dependency_disabled"
          end
        end
        installation.update!(enabled: enabled, activation_generation: generation + 1)
        Activity::Recorder.record!(actor: fresh, action: enabled ? "extension.enabled" : "extension.disabled",
          details: { version: installation.version, digest: installation.package_sha256 })
        installation
      end
    end

    def same_selection?(installation, registry)
      entry = registry.entries[installation.module_id]
      entry && installation.site.install_id == registry.site && installation.engine_generation == registry.generation &&
        installation.engine_fingerprint == registry.fingerprint && installation.version == entry.version &&
        installation.package_sha256 == entry.package_sha256 && installation.manifest_sha256 == entry.manifest.digest
    end

    def active_selection?(id, records, registry)
      row = records[id]
      row && same_selection?(row, registry) && withdrawal_compatible?(id, registry) && registry.entries.fetch(id).manifest.dependencies.keys.all? do |dependency|
        active_selection?(dependency, records, registry)
      end
    end

    def withdrawal_compatible?(id, registry)
      withdrawals = Railpress::Extensions::CandidateWithdrawals
      withdrawals.supports?(registry.entries.fetch(id).manifest) || !withdrawals.subjects(registry.site, id).exists?
    end

    def collision?(id)
      slug = "extensions/#{id}"
      Page.where("slug = ? OR slug LIKE ?", slug, "#{slug}/%").exists? ||
        Redirect.where("source_path = ? OR source_path LIKE ?", "/#{slug}", "/#{slug}/%").exists?
    end
  end
end
