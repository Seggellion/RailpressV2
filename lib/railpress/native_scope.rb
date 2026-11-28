# frozen_string_literal: true

require "json"

module Railpress
  # Startup fence for the explicitly authorized disposable native helpers.
  module NativeScope
    module_function
    def verify!
      raise "Unqualified native profile" unless ENV["RAILPRESS_NATIVE_PROFILE"] == "isolated-synthetic-nginx-v1"
      root = File.realpath(ENV.fetch("RAILPRESS_NATIVE_TEST_REGISTRY"))
      profile = ENV["RAILPRESS_NATIVE_TEST_PROFILE"]
      # The controller owns admission. Load its registry reader separately
      # from the candidate's Rails constants, including on the v1 bridge.
      guard = Module.new
      load(File.join(__dir__, "test_database.rb"), guard)
      database = guard.const_get(:Railpress, false).const_get(:TestDatabase, false)
      raise "Unknown synthetic native profile" if profile && !database::PROFILES.key?(profile)
      path = File.join(root, ".local/state", database.registry_file(profile))
      stat = File.stat(path)
      raise "Unsafe native registry" unless stat.uid == Process.uid && (stat.mode & 0o077).zero? && !File.symlink?(path)
      registry = JSON.parse(File.read(path))
      registry = registry.fetch(profile) if profile
      target = registry.fetch(ENV.fetch("RAILPRESS_DB_ADAPTER"))
      raise "Native synthetic profile identity" if profile && target["run_id"] != database::PROFILES.fetch(profile)
      database.validate!(target, environment: "test", confirmed: "railpress-synthetic-only")
      mapping = { "ADAPTER" => "adapter", "HOST" => "host", "PORT" => "port", "NAME" => "database", "USER" => "username", "PASSWORD" => "password" }
      raise "Native database mismatch" unless mapping.all? { |key, field| ENV["RAILPRESS_DB_#{key}"] == target[field].to_s } &&
        target["instance_id"] == ENV["RAILPRESS_NATIVE_TEST_INSTANCE"] &&
        File.realpath(target["data_directory"]).start_with?(File.join(root, ".local/state") + "/")
      database.verify!(target, environment: "test", confirmed: "railpress-synthetic-only")
    end
    def boot!
      directory = File.dirname(ENV.fetch("BUNDLE_GEMFILE"))
      require File.join(directory, "config/application")
      # Configure before Rails creates its cache; a late initializer is too late.
      Rails.application.config.cache_store = :memory_store
      Rails.application.initializer "railpress.native_shared_mail", after: :load_config_initializers do |application|
        location = File.join(File.dirname(ENV.fetch("RAILPRESS_PRIVATE_STATE_ROOT")), "mail")
        FileUtils.mkdir_p(location, mode: 0o700)
        application.config.action_mailer.file_settings = { location: location }
      end
      require File.join(directory, "config/environment")
      installation!
    end
    def installation!
      raise "Native installation mismatch" unless Railpress::BootstrapState.for_application.installed? &&
        Site.pluck(:install_id) == [ ENV.fetch("RAILPRESS_NATIVE_INSTALL_ID") ]
    end
  end
end
