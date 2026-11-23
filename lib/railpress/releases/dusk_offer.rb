# frozen_string_literal: true

module Railpress
  module Releases
    module DuskOffer
      ASSET_NAME = "dusk-update.json"
      INVENTORY_PATH = "lib/railpress/#{ASSET_NAME}".freeze
      PACKAGE_ROOT = "themes/bundled-dusk"
      LIMIT = 4096
      module_function

      def parse(bytes)
        value = Releases.parse(bytes, limit: LIMIT)
        Releases.keys!(value, %w[format id version digest theme_api minimum_core notes])
        raise Invalid, "dusk_offer_format" unless value["format"] == "railpress.dusk-offer.v1" && value["id"] == "dusk"
        ThemePackage.identity!(value["id"], value["version"], value["digest"])
        raise Invalid, "dusk_offer_version" unless SEMVER.match?(value["version"])
        Releases.integer!(value["theme_api"], 1, 1000)
        raise Invalid, "dusk_minimum_core" unless value["minimum_core"].is_a?(String) && value["minimum_core"].bytesize <= 80 && SEMVER.match?(value["minimum_core"])
        Releases.text!(value["notes"], 2048)
        value
      rescue ThemePackage::Invalid
        raise Invalid, "dusk_offer_identity"
      end

      def verify!(manifest, bytes)
        inventory = manifest.fetch("files").fetch(INVENTORY_PATH) { raise Invalid, "dusk_offer_not_listed" }
        raise Invalid, "dusk_offer_integrity" unless bytes.is_a?(String) && bytes.bytesize <= LIMIT &&
          inventory["bytes"] == bytes.bytesize && inventory["sha256"] == Digest::SHA256.hexdigest(bytes)
        value = parse(bytes)
        compatibility = manifest.fetch("compatibility")
        raise Invalid, "dusk_offer_contract" unless compatibility["themes"].include?(value.slice("id", "version", "digest")) &&
          compatibility["theme_api"] == value["theme_api"] && Releases.compare_versions(manifest.fetch("version"), value["minimum_core"]) >= 0 &&
          %w[manifest.json signature.json].all? { |name| manifest["files"].key?("#{PACKAGE_ROOT}/#{name}") }
        value
      end

      def bind(files, compatibility, metadata, bundle:, minimum_core:, notes:)
        raise Invalid, "dusk_bundle_required" unless bundle.is_a?(ThemePackage::Bundle)
        version = Releases.parse(files.fetch("lib/railpress/dusk.json").fetch("bytes"), limit: LIMIT)
        identity = bundle.manifest.slice("id", "version", "theme_api")
        raise Invalid, "dusk_definition_mismatch" unless identity == version.slice("id", "version", "theme_api")

        data = identity.merge("format" => "railpress.dusk-offer.v1", "digest" => bundle.digest, "minimum_core" => minimum_core, "notes" => notes)
        bytes = Releases.canonical(data)
        embedded = bundle.files.to_h { |path, content| [ "#{PACKAGE_ROOT}/#{path}", { "bytes" => content, "mode" => 0o644 } ] }
        embedded[INVENTORY_PATH] = { "bytes" => bytes, "mode" => 0o644 }
        raise Invalid, "dusk_binding_collision" unless (files.keys & embedded.keys).empty?
        inventory = embedded.transform_values { |source| { "bytes" => source["bytes"].bytesize, "sha256" => Digest::SHA256.hexdigest(source["bytes"]) } }
        verify!(metadata.merge("files" => inventory, "compatibility" => compatibility), bytes)
        files.merge(embedded)
      end
    end
  end
end
