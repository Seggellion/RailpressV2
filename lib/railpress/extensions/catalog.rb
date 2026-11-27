# frozen_string_literal: true

module Railpress
  module Extensions
    # A catalog identifies reviewed artifacts. EngineSet still admits executable bytes.
    class Catalog
      FORMAT = "railpress.module-catalog.v1"
      LIMIT = 64 * 1024
      LIFETIME = 86_400
      attr_reader :id, :digest, :entries

      def initialize(bytes, trust:, pin:, id:, now: Time.now.to_i)
        Extensions.id!(id)
        Releases.keys!(pin, %w[id sequence sha256])
        Releases.identity!(pin["sha256"])
        Extensions.generation!(pin["sequence"], minimum: 1)
        document = trust.verify!(bytes, purpose: FORMAT, now: now)
        Releases.keys!(document, %w[format id sequence issued_at expires_at entries])
        issued = Extensions.generation!(document["issued_at"], minimum: 1)
        digest = Extensions.digest(document)
        unless issued <= now && document["expires_at"].between?(issued + 1, issued + LIFETIME) &&
            document.values_at("id", "sequence") == [ id, pin["sequence"] ] && pin.values_at("id", "sha256") == [ id, digest ]
          raise Invalid, "module_catalog_pin_or_freshness"
        end
        rows = document["entries"]
        raise Invalid, "module_catalog_size" unless rows.is_a?(Array) && rows.length.between?(1, 24)
        @entries = rows.each_with_object({}) do |row, index|
          validate_entry!(row)
          raise Invalid, "module_catalog_duplicate" if index.key?(row["id"])
          index[row["id"]] = row
        end.freeze
        @id, @digest = document.fetch("id"), digest.freeze
        freeze
      end

      def self.compatible?(row, core: Product::VERSION, api: Product::EXTENSION_API)
        Manifest.includes_version?(row.fetch("core"), core) && Manifest.includes_number?(row.fetch("extension_api"), api)
      end

      def self.setup_path!(id, path)
        setup = %r{\A/admin/modules/#{Regexp.escape(Extensions.id!(id))}/manage(?:/[a-z][a-z0-9-]{0,39})?\z}
        raise Invalid, "module_catalog_setup_path" unless path.is_a?(String) && setup.match?(path)
        path
      end

      private

      def validate_entry!(row)
        Releases.keys!(row, %w[id name summary version channel core extension_api publisher license manifest_sha256 package_sha256 plan_sha256 artifact setup_path])
        Extensions.id!(row["id"])
        Extensions.version!(row["version"])
        %w[name publisher license].each { |field| Releases.text!(row[field], 120) }
        Releases.text!(row["summary"], 500)
        %w[manifest_sha256 package_sha256 plan_sha256].each { |field| Releases.identity!(row[field]) }
        Manifest.version_range!(row["core"])
        Manifest.window!(row["extension_api"], minimum: 1)
        expected = "packages/#{row.fetch('id')}/#{row.fetch('version')}/#{row.fetch('package_sha256')}/package.tar.gz"
        unless row["artifact"] == expected && %w[stable alpha beta].include?(row["channel"])
          raise Invalid, "module_catalog_artifact"
        end
        self.class.setup_path!(row["id"], row["setup_path"])
      end
    end
  end
end
