# frozen_string_literal: true

require "json"
require_relative "product_metadata"

module Railpress
  module Product
    DEFINITION = ProductMetadata.load(__dir__).freeze
    VERSION = DEFINITION.fetch("version")
    CHANNEL = DEFINITION.fetch("channel")
    FAMILY = "Railpress 2.0"
    SCHEMA = DEFINITION.fetch("schema")
    JOB_PAYLOAD = 1
    THEME_API = 1
    EXTENSION_API = DEFINITION.fetch("extension_api")
    # R8 media intent and prefix bindings require a core that understands them.
    CONFIGURATION = 2
    SECURITY_CLOCK = 2
    NATIVE_PROFILE = "linux-staging-v1"
  end
end
