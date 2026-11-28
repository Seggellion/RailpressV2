module Releases
  module Context
    module_function
    def current
      connection = ActiveRecord::Base.connection
      adapter = connection.adapter_name
      engine = adapter == "PostgreSQL" ? "postgresql" : (adapter == "Mysql2" ? "mysql2" : nil)
      raise Railpress::Releases::Invalid, "database_engine" unless engine
      version = connection.select_value(engine == "postgresql" ? "SHOW server_version" : "SELECT VERSION()").to_s[/\A\d+\.\d+(?:\.\d+)?/]
      themes = verified_themes
      packages = local_packages
      { "ruby" => RUBY_VERSION, "rails" => Rails.version, "database_engine" => engine, "database_version" => version,
        "native_profile" => Railpress::Product::NATIVE_PROFILE,
        "themes" => themes,
        "packages" => packages }
    end

    def verified_themes
      themes = ThemeInstallation.where(status: "validated").order(:id).limit(33).to_a
      raise Railpress::Releases::Invalid, "theme_inventory" if themes.length > 32
      themes.map do |theme|
        Themes::Storage.load(theme)
        { "id" => theme.theme_key, "version" => theme.version, "digest" => theme.digest }
      end
    end

    def local_packages(registry: Railpress::Extensions.registry)
      site = Site.find_by!(singleton_key: 1)
      packages = ThemeInstallation.where(site: site).where("status = ? OR ever_active_at IS NOT NULL", "validated").order(:id).limit(33).map do |theme|
        bundle = Themes::Storage.load(theme, allow_removed: true)
        overlays = theme.theme_overlays.order(:number).limit(257).map do |row|
          Railpress::Extensions.digest(row.attributes.slice("id", "number", "options", "media_details"))
        end
        { "id" => theme.theme_key, "version" => theme.version, "digest" => bundle.digest,
          "schema" => bundle.manifest.fetch("schema_version"), "overlays" => overlays }
      end
      modules = if ExtensionInstallation.table_exists?
        ExtensionInstallation.where(site: site).order(:module_id).limit(33).map { |row| module_context(row, registry) }
      else
        []
      end
      installed = modules.select { |item| item["presence"] == "installed" }.map { |item| item["id"] }
      raise Railpress::Releases::Invalid, "local_engine_lock_inventory" unless registry.entries.keys.sort == installed.sort &&
        (!registry.site || registry.site == site.install_id)
      jobs = SolidQueue::Job.where(finished_at: nil).distinct.order(:class_name).limit(129).pluck(:class_name)
      Railpress::Releases::PackageContext.verify!({ "format" => Railpress::Releases::PackageContext::FORMAT, "site" => site.install_id,
        "core" => Railpress::Product::VERSION, "extension_api" => Railpress::Product::EXTENSION_API,
        "anchor" => registry.engine_set&.core_anchor || Railpress::Product::VERSION,
        "generation" => registry.generation, "fingerprint" => registry.fingerprint, "modules" => modules, "themes" => packages, "jobs" => jobs })
    end

    def module_context(row, registry)
      entry = if row.package_state == "installed"
        candidate = registry.entries[row.module_id]
        raise Railpress::Releases::Invalid, "local_engine_lock_identity" unless candidate && Extensions::Activation.same_selection?(row, registry)
        candidate
      else
        Railpress::Extensions.retained_entry!(row)
      end
      raise Railpress::Releases::Invalid, "local_module_migration_hold" unless Railpress::Extensions::Migrations.applied?(site: row.site, entry: entry)
      classes = entry.manifest.files.keys.grep(%r{\Aapp/jobs/.*\.rb\z}).map do |path|
        path.delete_prefix("app/jobs/").delete_suffix(".rb").camelize
      end.sort
      { "id" => row.module_id, "version" => row.version, "package" => row.package_sha256, "manifest" => row.manifest_sha256,
        "schema" => row.module_schema, "jobs" => row.job_revision, "enabled" => row.enabled, "presence" => row.package_state,
        "core" => entry.manifest.data.fetch("core"), "data" => entry.manifest.data_contract, "jobs_classes" => classes }
    end
  end
end
