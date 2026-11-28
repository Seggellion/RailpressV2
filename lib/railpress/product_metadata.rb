# frozen_string_literal: true

require "json"

module Railpress
  module ProductMetadata
    BRIDGE = "product-package-contract.json"
    FORMAT = "railpress.product-package-contract.v1"
    module_function

    def load(directory)
      public_data = JSON.parse(File.read(File.join(directory, "product.json")))
      bridge_path = File.join(directory, BRIDGE)
      return public_data unless File.exist?(bridge_path)
      apply(public_data, JSON.parse(File.read(bridge_path)))
    end

    def apply(public_data, contract)
      unless public_data.is_a?(Hash) && contract.is_a?(Hash) &&
          contract.keys.sort == %w[extension_api format predecessor_schema schema version] &&
          (public_data.keys.sort == %w[channel configuration format jobs schema security_clock theme_api version]) &&
          contract["format"] == FORMAT && public_data["format"] == "railpress.product.v1" &&
          contract["version"] == public_data["version"] && contract["predecessor_schema"] == public_data["schema"] &&
          contract["predecessor_schema"].is_a?(Integer) && contract["predecessor_schema"].positive? &&
          contract["schema"].is_a?(Integer) && contract["schema"].between?(contract["predecessor_schema"] + 1, 100_000) &&
          contract["extension_api"].is_a?(Integer) && contract["extension_api"].between?(1, 1000)
        raise ArgumentError, "Invalid bridge product contract"
      end
      public_data.merge(contract.slice("schema", "extension_api"))
    end
  end
end
