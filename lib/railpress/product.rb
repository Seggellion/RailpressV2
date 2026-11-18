# frozen_string_literal: true

require "json"

module Railpress
  module Product
    DEFINITION = JSON.parse(File.read(File.join(__dir__, "product.json"))).freeze
    VERSION = DEFINITION.fetch("version")
    CHANNEL = DEFINITION.fetch("channel")
    FAMILY = "Railpress 2.0"
    SCHEMA = 14
    JOB_PAYLOAD = 1
    THEME_API = 1
    # R8 media intent and prefix bindings require a core that understands them.
    CONFIGURATION = 2
    SECURITY_CLOCK = 2
    NATIVE_PROFILE = "linux-staging-v1"
  end
end
