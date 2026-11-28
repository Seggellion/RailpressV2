# frozen_string_literal: true

require_relative "releases"
require_relative "test_database"

module Railpress
  module Extensions
    Invalid = Releases::Invalid
    ID = /\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/
    GENERATION_MAX = 2**53 - 1

    module_function

    def id!(value)
      raise Invalid, "extension_id" unless value.is_a?(String) && value.bytesize <= 30 && ID.match?(value)
      value
    end

    def version!(value)
      raise Invalid, "extension_version" unless value.is_a?(String) && value.bytesize <= 80 && Releases::SEMVER.match?(value)
      value
    end

    def generation!(value, minimum: 0)
      Releases.integer!(value, minimum, GENERATION_MAX)
      value
    end

    def uuid!(value)
      raise Invalid, "extension_uuid" unless value.is_a?(String) && Releases::UUID.match?(value)
      value
    end

    def digest(value)
      Digest::SHA256.hexdigest(Releases.canonical(value))
    end

    def freeze_tree(value)
      case value
      when Hash then value.each { |key, item| key.freeze; freeze_tree(item) }
      when Array then value.each { |item| freeze_tree(item) }
      end
      value.freeze
    end

    def registry
      @registry ||= Registry.empty
    end

    def retained_entry!(row)
      set = registry.engine_set
      raise Invalid, "retained_package_lock_missing" unless set && set.site == row.site.install_id
      set.retained_entry!(id: row.module_id, version: row.version, archive: row.package_sha256, digest: row.manifest_sha256)
    end

    def boot!(app_root:, environment:)
      root = ENV["RAILPRESS_EXTENSION_ROOT"]
      site = ENV["RAILPRESS_EXTENSION_SITE"]
      return registry if root.nil? && site.nil?
      uuid!(site)
      synthetic = environment == "test" && ENV["RAILPRESS_TEST_CONFIRM"] == "railpress-synthetic-only"
      core_anchor = Product::VERSION
      if synthetic
        target = TestDatabase.load!(root: app_root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
        TestDatabase.verify!(target)
        base = File.realpath(File.join(app_root, ".local/state"))
        raise Invalid, "extension_test_root" unless root&.start_with?("#{base}/")
      elsif environment == "production" && ENV["RAILPRESS_NATIVE_PROFILE"] == "isolated-synthetic-nginx-v1"
        require_relative "native_scope"
        identity = NativeScope.verify!
        base = File.realpath(ENV.fetch("RAILPRESS_NATIVE_TEST_REGISTRY"))
        profile = ENV["RAILPRESS_NATIVE_TEST_PROFILE"]
        namespace = { "w03_bridge" => "w03", "w03_restore" => "w03", "w04_recruitment" => "w04", "w04_recruitment_final" => "w04" }[profile]
        raise Invalid, "extension_native_scope" unless identity && namespace && site == ENV["RAILPRESS_NATIVE_INSTALL_ID"] &&
          root&.start_with?("#{base}/.local/state/#{namespace}/") && File.realpath(root) == root
        synthetic = true
        core_anchor = ENV.fetch("RAILPRESS_EXTENSION_CORE_ANCHOR", Product::VERSION)
        version!(core_anchor)
      end
      @registry = Registry.load(EngineSet.load(root: root, site: site, synthetic: synthetic, core_anchor: core_anchor))
    rescue KeyError, SystemCallError, TestDatabase::UnsafeTarget
      raise Invalid, "extension_boot_configuration", cause: nil
    end
  end
end

require_relative "extensions/candidate_withdrawals"
require_relative "extensions/manifest"
require_relative "extensions/trust"
require_relative "extensions/catalog"
require_relative "extensions/engine_set"
require_relative "extensions/registry"
