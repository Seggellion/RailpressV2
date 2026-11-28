# frozen_string_literal: true

module Railpress
  module Extensions
    class Manifest
      LIMIT = 96 * 1024
      FILE_LIMIT = 2 * 1024 * 1024
      PACKAGE_LIMIT = 16 * 1024 * 1024
      FORMAT = "railpress.extension.v1"

      attr_reader :data, :digest

      def initialize(bytes)
        @data = Releases.parse(bytes, limit: LIMIT)
        Releases.keys!(data, %w[format id name version core extension_api entrypoint engine dependencies provides routes permissions slots data_contract migrations license provenance files])
        raise Invalid, "extension_format" unless data["format"] == FORMAT
        Extensions.id!(id)
        Extensions.version!(version)
        %w[name license provenance].each { |field| Releases.text!(data[field], field == "provenance" ? 512 : 120) }
        self.class.version_range!(data["core"])
        self.class.window!(data["extension_api"], minimum: 1)
        validate_engine!
        validate_declarations!
        validate_inventory!
        @digest = Extensions.digest(data).freeze
        Extensions.freeze_tree(data)
        freeze
      end

      def id = data.fetch("id")
      def version = data.fetch("version")
      def files = data.fetch("files")
      def migrations = data.fetch("migrations")
      def dependencies = data.fetch("dependencies")
      def entrypoint = data.fetch("entrypoint")
      def engine = data.fetch("engine")
      def routes = data.fetch("routes")
      def data_contract = data.fetch("data_contract")

      def compatible?(core: Product::VERSION, api: Product::EXTENSION_API)
        self.class.includes_version?(data["core"], core) && self.class.includes_number?(data["extension_api"], api)
      end

      def self.version_range!(range)
        Releases.keys!(range, %w[min max_exclusive])
        range.each_value { |value| Extensions.version!(value) }
        raise Invalid, "extension_version_range" unless Releases.compare_versions(range["min"], range["max_exclusive"]).negative?
      end

      def self.includes_version?(range, version)
        Releases.compare_versions(version, range.fetch("min")) >= 0 &&
          Releases.compare_versions(version, range.fetch("max_exclusive")) < 0
      end

      def self.window!(value, minimum: 0)
        raise Invalid, "extension_version_window" unless value.is_a?(Array) && value.length == 2
        value.each { |number| Releases.integer!(number, minimum, 2**31 - 1) }
        raise Invalid, "extension_version_window" if value.first > value.last
      end

      def self.includes_number?(range, number)
        number.is_a?(Integer) && number.between?(*range)
      end

      private

      def validate_engine!
        namespace = id.split("-").map(&:capitalize).join
        expected = "lib/#{id.tr('-', '_')}/engine.rb"
        raise Invalid, "extension_entrypoint" unless entrypoint == expected && engine == "#{namespace}::Engine"
      end

      def validate_declarations!
        raise Invalid, "extension_dependencies" unless dependencies.is_a?(Hash) && dependencies.length <= 16 && !dependencies.key?(id)
        dependencies.each do |name, range|
          Extensions.id!(name)
          self.class.version_range!(range)
        end
        %w[provides permissions slots].each do |field|
          values = data[field]
          raise Invalid, "extension_declarations" unless values.is_a?(Array) && values.length <= 32 && values == values.uniq &&
            values.all? { |value| value.is_a?(String) && value.start_with?("#{id}.") && value.match?(/\A[a-z0-9-]+(?:\.[a-z][a-z0-9_-]{0,30}){1,3}\z/) }
        end
        Releases.keys!(routes, %w[public admin navigation])
        raise Invalid, "extension_routes" unless %w[public admin].all? { |key| [ true, false ].include?(routes[key]) }
        provides = data.fetch("provides")
        if provides.include?("#{id}.forms") && !routes.values_at("public", "admin").any?
          raise Invalid, "extension_form_mount"
        end
        raise Invalid, "extension_review_mount" if provides.include?("#{id}.reviews") && !routes["admin"]
        if routes["navigation"]
          raise Invalid, "extension_navigation" unless routes["admin"]
          Releases.text!(routes["navigation"], 60)
        end
        Releases.keys!(data_contract, %w[schema_read schema_write jobs_read jobs_write])
        data_contract.each_value { |range| self.class.window!(range) }
      end

      def validate_inventory!
        raise Invalid, "extension_inventory" unless files.is_a?(Hash) && files.length.between?(1, 128) && files.key?(entrypoint) &&
          files.keys.map(&:downcase).uniq.length == files.length
        total = 0
        files.each do |path, entry|
          Releases.path!(path)
          raise Invalid, "extension_path" unless path.start_with?("app/", "config/", "db/migrate/", "lib/") || %w[LICENSE THIRD_PARTY_NOTICES.md].include?(path)
          Releases.keys!(entry, %w[sha256 size mode])
          Releases.identity!(entry["sha256"])
          Releases.integer!(entry["size"], 0, FILE_LIMIT)
          raise Invalid, "extension_file_mode" unless %w[0644 0755].include?(entry["mode"])
          total += entry["size"]
        end
        raise Invalid, "extension_inventory_size" if total > PACKAGE_LIMIT
        raise Invalid, "extension_migrations" unless migrations.is_a?(Array) && migrations.length <= 32
        versions = migrations.map do |migration|
          Releases.keys!(migration, %w[version path sha256])
          version = migration["version"]
          path = migration["path"]
          raise Invalid, "extension_migration_identity" unless version.is_a?(String) && version.match?(/\A[1-9][0-9]{13}\z/) &&
            path.is_a?(String) && path.match?(/\Adb\/migrate\/#{version}_[a-z][a-z0-9_]*\.rb\z/) && files[path] &&
            files[path]["sha256"] == migration["sha256"]
          version
        end
        raise Invalid, "extension_migrations" unless versions == versions.sort.uniq &&
          migrations.map { |row| row["path"] }.sort == files.keys.grep(/\Adb\/migrate\//).sort
      end
    end
  end
end
