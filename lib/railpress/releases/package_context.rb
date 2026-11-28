# frozen_string_literal: true

module Railpress
  module Releases
    module PackageContext
      FORMAT = "railpress.local-packages.v1"
      module_function

      def verify!(context)
        Releases.keys!(context, %w[format site core anchor extension_api generation fingerprint modules themes jobs])
        raise Invalid, "local_package_context" unless context["format"] == FORMAT && UUID.match?(context["site"].to_s)
        Releases.integer!(context["extension_api"], 1, 1000)
        %w[core anchor].each { |field| version!(context[field]) }
        Releases.integer!(context["generation"], 0, 2**53 - 1)
        Releases.identity!(context["fingerprint"])
        modules = context["modules"]
        themes = context["themes"]
        jobs = context["jobs"]
        unless modules.is_a?(Array) && modules.size <= 32 && themes.is_a?(Array) && themes.size <= 32 &&
            jobs.is_a?(Array) && jobs.size <= 128 && jobs == jobs.uniq.sort &&
            jobs.all? { |name| name.match?(/\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*){0,3}\z/) }
          raise Invalid, "local_package_inventory"
        end
        modules.each { |item| module_identity!(item) }
        themes.each { |item| theme_identity!(item) }
        raise Invalid, "local_package_duplicate" unless modules.map { |row| row["id"] }.uniq == modules.map { |row| row["id"] } &&
          themes.map { |row| row.values_at("id", "version", "digest") }.uniq.size == themes.size
        context
      rescue NoMethodError, ArgumentError, TypeError
        raise Invalid, "local_package_context", cause: nil
      end

      def module_identity!(item)
        Releases.keys!(item, %w[id version package manifest schema jobs enabled presence core data jobs_classes])
        raise Invalid, "local_module_id" unless item["id"].is_a?(String) && item["id"].match?(/\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/) && item["id"].size <= 30
        version!(item["version"])
        %w[package manifest].each { |field| Releases.identity!(item[field]) }
        %w[schema jobs].each { |field| Releases.integer!(item[field], 0, 2**31 - 1) }
        unless %w[installed retained].include?(item["presence"]) && [ true, false ].include?(item["enabled"]) &&
            (item["presence"] == "installed" || !item["enabled"])
          raise Invalid, "local_module_state"
        end
        version_window!(item["core"])
        Releases.keys!(item["data"], %w[schema_read schema_write jobs_read jobs_write])
        item["data"].each_value { |window| number_window!(window) }
        classes = item["jobs_classes"]
        raise Invalid, "local_job_namespace" unless classes.is_a?(Array) && classes.size <= 32 && classes.uniq == classes &&
          classes.all? { |name| name.is_a?(String) && name.start_with?("#{item['id'].split('-').map(&:capitalize).join}::") &&
            name.match?(/\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*){1,3}\z/) }
      end

      def theme_identity!(item)
        Releases.keys!(item, %w[id version digest schema overlays])
        version!(item["version"])
        Releases.identity!(item["digest"])
        raise Invalid, "local_theme_identity" unless item["id"].is_a?(String) && item["id"].match?(/\A[a-z][a-z0-9-]{1,39}\z/) &&
          [ 1, 2 ].include?(item["schema"]) && item["overlays"].is_a?(Array) && item["overlays"].length <= 256
        item["overlays"].each { |digest| Releases.identity!(digest) }
      end

      def version!(value)
        raise Invalid, "local_version" unless value.is_a?(String) && value.bytesize <= 80 && SEMVER.match?(value)
      end

      def version_window!(range)
        Releases.keys!(range, %w[min max_exclusive])
        range.each_value { |value| version!(value) }
        raise Invalid, "local_version_window" unless Releases.compare_versions(range["min"], range["max_exclusive"]).negative?
      end

      def version_in?(range, value)
        Releases.compare_versions(value, range.fetch("min")) >= 0 && Releases.compare_versions(value, range.fetch("max_exclusive")) < 0
      end

      def number_window!(range)
        unless range.is_a?(Array) && range.length == 2 && range.all? { |number| number.is_a?(Integer) && number.between?(0, 2**31 - 1) } && range.first <= range.last
          raise Invalid, "local_package_window"
        end
      end

      def required?(context)
        context["modules"].any? || context["themes"].any? { |theme| theme["schema"] == 2 } ||
          context["jobs"].any? { |job| job.include?("::") || job == "ValidateThemeUploadJob" }
      end

      def admit!(manifest, local)
        verify!(local)
        return true unless required?(local) || manifest["format"] == "railpress.release.v2"
        unless manifest.fetch("files", {}).key?("lib/railpress/releases/package_context.rb")
          raise Invalid, "package_reader_required"
        end
        if manifest["format"] == "railpress.release.v2"
          policy = manifest.fetch("package_policy")
          raise Invalid, "extension_api" unless policy["extension_api"] == local["extension_api"]
          raise Invalid, "package_predecessor" unless version_in?(policy["predecessor"], local["core"])
          dusk = policy.fetch("dusk")
          raise Invalid, "bundled_dusk_identity" unless local["themes"].any? { |theme| dusk.all? { |key, value| theme[key] == value } }
        end
        local["modules"].each do |row|
          raise Invalid, "module_core_window" unless version_in?(row.fetch("core"), manifest.fetch("version"))
          { "schema_read" => "schema", "schema_write" => "schema", "jobs_read" => "jobs", "jobs_write" => "jobs" }.each do |window, field|
            raise Invalid, "module_data_window" unless row.fetch(field).between?(*row.fetch("data").fetch(window))
          end
        end
        installed_jobs = local["modules"].select { |row| row["presence"] == "installed" }.flat_map { |row| row["jobs_classes"] }
        unresolved = local["jobs"].reject { |name| installed_jobs.include?(name) || manifest.fetch("files").key?(job_path(name)) }
        raise Invalid, "module_job_reader" unless unresolved.empty?
        true
      end

      def job_path(name)
        snake = name.gsub("::", "/").gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2').gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase
        "app/jobs/#{snake}.rb"
      end
    end
  end
end
