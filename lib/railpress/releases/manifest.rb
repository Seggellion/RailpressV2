# frozen_string_literal: true

require_relative "package_context"

module Railpress
  module Releases
    module Manifest
      MAX_PACKAGE = 32 * 1024 * 1024
      MAX_EXPANDED = 128 * 1024 * 1024
      REQUIRED = %w[db/schema_postgresql.rb db/schema_mysql2.rb scripts/themes/smoke.rb scripts/themes/navigation_contract_fixture.rb .ruby-version config.ru Rakefile bin/rake Gemfile Gemfile.lock LICENSE config/application.rb config/routes.rb bin/rails lib/railpress/product.rb lib/railpress/product.json lib/railpress/dusk.json lib/railpress/security_clock.rb public/assets/.manifest.json themes/dusk/assets/public.css themes/dusk/LICENSE.txt].concat(ThemePackage::FAMILIES.map { |family| "themes/dusk/templates/#{family}.html.erb" }).freeze
      module_function
      def validate!(value)
        format = value.is_a?(Hash) && value["format"]
        raise Invalid, "manifest_format" unless %w[railpress.release.v1 railpress.release.v2].include?(format)
        keys = %w[format version channel sequence published_at expires_at package files compatibility changelog provenance]
        keys << "package_policy" if format == "railpress.release.v2"
        Releases.keys!(value, keys)
        raise Invalid, "product_semver" unless value["version"].is_a?(String) && value["version"].bytesize <= 80 && SEMVER.match?(value["version"])
        # Channel syntax is independent of production/signing authorization.
        channel = value["channel"]
        valid_channel = channel == "development" ||
          (channel == "alpha" && value["version"].match?(/-alpha\./)) ||
          (channel == "stable" && !value["version"].split("+").first.include?("-"))
        raise Invalid, "unqualified_channel" unless valid_channel
        Releases.integer!(value["sequence"], 1, 2**53 - 1)
        %w[published_at expires_at].each { |field| Releases.integer!(value[field], 1, 2**53 - 1) }
        raise Invalid, "manifest_validity" unless (value["expires_at"] - value["published_at"]).between?(1, 7 * 86_400)
        Releases.text!(value["changelog"], 16_384)
        Releases.text!(value["provenance"], 2048)
        package = value["package"]
        Releases.keys!(package, %w[sha256 bytes])
        Releases.identity!(package["sha256"])
        Releases.integer!(package["bytes"], 1, MAX_PACKAGE)
        files = value["files"]
        required = value["version"].split(".").first.to_i >= 2 ? REQUIRED : REQUIRED - [ "lib/railpress/dusk.json" ]
        raise Invalid, "file_inventory" unless files.is_a?(Hash) && files.length.between?(required.length, 4096) && (required - files.keys).empty?
        names = {}
        total = 0
        files.each do |name, row|
          Releases.path!(name)
          raise Invalid, "normalized_duplicate" if names[name.downcase]
          names[name.downcase] = true
          Releases.keys!(row, %w[sha256 bytes mode])
          Releases.identity!(row["sha256"])
          Releases.integer!(row["bytes"], 0, 8 * 1024 * 1024)
          raise Invalid, "file_permissions" unless row["mode"] == 0o644 || (row["mode"] == 0o755 && name.start_with?("bin/", "scripts/"))
          total += row["bytes"]
        end
        raise Invalid, "expanded_limit" if total > MAX_EXPANDED
        compatibility!(value["compatibility"])
        package_policy!(value) if format == "railpress.release.v2"
        value
      end
      def package_policy!(manifest)
        policy = manifest.fetch("package_policy")
        Releases.keys!(policy, %w[extension_api predecessor dusk])
        Releases.integer!(policy["extension_api"], 1, 1000)
        PackageContext.version_window!(policy["predecessor"])
        dusk = policy["dusk"]
        Releases.keys!(dusk, %w[id version digest])
        raise Invalid, "bundled_dusk_identity" unless dusk["id"] == "dusk" && manifest["compatibility"]["themes"].include?(dusk)
        raise Invalid, "package_reader_required" unless manifest["files"].key?("lib/railpress/releases/package_context.rb")
      end
      def compatibility!(c)
        Releases.keys!(c, %w[ruby rails databases schema_read schema_write jobs_read jobs_write theme_api themes configuration security_clock native_profile prior_versions assets_sha256])
        %w[ruby rails].each { |field| requirement!(c[field]) }
        Releases.keys!(c["databases"], %w[postgresql mysql2])
        c["databases"].each_value { |range| requirement!(range) }
        %w[schema_read schema_write jobs_read jobs_write].each do |field|
          range = c[field]
          raise Invalid, "compatibility_range" unless range.is_a?(Array) && range.length == 2 && range.all? { |v| v.is_a?(Integer) && v.between?(1, 100_000) } && range.first <= range.last
        end
        %w[theme_api configuration security_clock].each { |field| Releases.integer!(c[field], 1, 1000) }
        raise Invalid, "native_profile" unless c["native_profile"] == Product::NATIVE_PROFILE
        Releases.identity!(c["assets_sha256"])
        raise Invalid, "prior_versions" unless c["prior_versions"].is_a?(Array) && c["prior_versions"].length.between?(1, 16) && c["prior_versions"].all? { |v| v.is_a?(String) && v.bytesize <= 80 && SEMVER.match?(v) }
        raise Invalid, "theme_inventory" unless c["themes"].is_a?(Array) && c["themes"].length.between?(1, 32) && c["themes"].any? { |row| row.is_a?(Hash) && row["id"] == "dusk" }
        raise Invalid, "duplicate_theme" unless c["themes"].uniq.length == c["themes"].length
        c["themes"].each do |row|
          Releases.keys!(row, %w[id version digest])
          raise Invalid, "theme_identity" unless row["id"].is_a?(String) && row["id"].match?(/\A[a-z][a-z0-9-]{1,39}\z/)
          raise Invalid, "theme_version" unless row["version"].is_a?(String) && SEMVER.match?(row["version"])
          Releases.identity!(row["digest"])
        end
      end
      def requirement!(text)
        raise Invalid, "version_constraint" unless text.is_a?(String) && text.bytesize <= 120 && text.match?(/\A(?:>=|<=|=|>|<) \d+\.\d+(?:\.\d+){0,2}(?:, (?:>=|<=|=|>|<) \d+\.\d+(?:\.\d+){0,2})*\z/)
        Gem::Requirement.new(text.split(", "))
      rescue Gem::Requirement::BadRequirementError
        raise Invalid, "version_constraint"
      end
      def compatible!(m, context)
        c = m.fetch("compatibility")
        %w[ruby rails].each { |field| raise Invalid, "incompatible_#{field}" unless requirement!(c[field]).satisfied_by?(Gem::Version.new(context.fetch(field))) }
        raise Invalid, "database_engine" unless %w[postgresql mysql2].include?(context["database_engine"])
        raise Invalid, "database_version" unless requirement!(c["databases"].fetch(context["database_engine"])).satisfied_by?(Gem::Version.new(context.fetch("database_version")))
        { "schema_read" => Product::SCHEMA, "schema_write" => Product::SCHEMA, "jobs_read" => Product::JOB_PAYLOAD, "jobs_write" => Product::JOB_PAYLOAD }.each do |field, version|
          raise Invalid, "incompatible_#{field}" unless (c[field].first..c[field].last).cover?(version)
        end
        { "theme_api" => Product::THEME_API, "configuration" => Product::CONFIGURATION, "security_clock" => Product::SECURITY_CLOCK }.each { |field, version| raise Invalid, "incompatible_#{field}" unless c[field] == version }
        raise Invalid, "prior_release" unless c["prior_versions"].include?(Product::VERSION)
        local = context["packages"]
        if m["format"] == "railpress.release.v2"
          raise Invalid, "local_package_context_missing" unless local
          raise Invalid, "package_context_core" unless local["core"] == Product::VERSION
        else
          raise Invalid, "theme_continuity" unless context["themes"].is_a?(Array) && context["themes"].all? { |row| c["themes"].include?(row) }
        end
        PackageContext.admit!(m, local) if local
        raise Invalid, "unsupported_host" unless context["native_profile"] == Product::NATIVE_PROFILE && RUBY_PLATFORM.include?("linux")
        raise Invalid, "product_not_newer" unless Releases.compare_versions(m["version"], Product::VERSION).positive?
        true
      end
    end
  end
end
