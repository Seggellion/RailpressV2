# frozen_string_literal: true

module Railpress
  module NativeHost
    class Config
      KEYS = %w[format deployment_id install_id registry_root engine database_instance_id environment_sha256 nginx_binary ruby_binary db_tools edge_port puma_ports scope max_snapshot_age_seconds dependency_hashes].freeze
      ENVIRONMENT = %w[RAILS_ENV SECRET_KEY_BASE RAILPRESS_HTTPS_ORIGIN RAILPRESS_PRIVATE_STATE_ROOT RAILPRESS_STORAGE_ROOT RAILPRESS_THEME_ROOT RAILPRESS_RELEASE_PUBLIC_TRUST RAILPRESS_NATIVE_PUBLIC_STATUS RAILPRESS_NATIVE_PROBE_TOKEN RAILPRESS_TLS_PROXY_IPS RAILPRESS_DB_ADAPTER RAILPRESS_DB_HOST RAILPRESS_DB_PORT RAILPRESS_DB_NAME RAILPRESS_DB_USER RAILPRESS_DB_PASSWORD RAILPRESS_WEBP_DECODER RAILPRESS_MEMBERSHIP_CONFIG RAILPRESS_EXTENSION_ROOT RAILPRESS_EXTENSION_SITE RAILPRESS_EXTENSION_CORE_ANCHOR].freeze
      attr_reader :root, :data, :app_environment
      def initialize(root)
        @root = F.directory!(root, private: true)
        @data = NativeHost.load_document(path("host.json"), maximum: 65_536)
        Releases.keys!(data.except("test_database_profile"), KEYS)
        if data.key?("test_database_profile")
          raise Error, "unknown_synthetic_database_profile" unless TestDatabase::PROFILES.key?(data["test_database_profile"])
        end
        raise Error, "unqualified_host_profile" unless data["format"] == "railpress.native-host.v1" && data["scope"] == "isolated-synthetic-nginx-v1" && Process.uid != 0
        %w[deployment_id install_id].each { |key| NativeHost.uuid!(data[key]) }
        Releases.identity!(data["environment_sha256"])
        Releases.keys!(data["dependency_hashes"], %w[Gemfile Gemfile.lock])
        data["dependency_hashes"].each_value { |value| Releases.identity!(value) }
        registry = F.directory!(data["registry_root"])
        raise Error, "database_engine" unless TestDatabase::ENGINES.key?(data["engine"])
        raise Error, "native_ruby" unless File.realpath(data["ruby_binary"]) == File.realpath(RbConfig.ruby)
        executable!(data["nginx_binary"], suffix: "/usr/sbin/nginx")
        Releases.keys!(data["db_tools"], %w[dump restore client])
        data["db_tools"].each_value { |value| executable!(value) }
        Releases.integer!(data["edge_port"], 49_152, 65_535)
        ports = data["puma_ports"]
        raise Error, "private_service_ports" unless ports.is_a?(Array) && ports.length == 2 &&
          ports.all? { |port| port.is_a?(Integer) && port.between?(49_152, 65_535) } && (ports + [ data["edge_port"] ]).uniq.length == 3
        Releases.integer!(data["max_snapshot_age_seconds"], 1, 3600)
        %w[releases shared run logs proxy snapshots approvals].each { |name| F.directory!(path(name), private: true) }
        bytes = F.read(path("shared", "environment.json"), maximum: 65_536)
        raise Error, "environment_identity" unless Digest::SHA256.hexdigest(bytes) == data["environment_sha256"]
        @app_environment = Releases.parse(bytes, limit: 65_536)
        raise Error, "private_environment_fields" unless (app_environment.keys - ENVIRONMENT).empty? &&
          ENVIRONMENT.first(10).all? { |key| app_environment[key].is_a?(String) } &&
          app_environment.values.all? { |value| value.is_a?(String) && value.bytesize <= 4096 && !value.include?("\0") }
        executable!(app_environment["RAILPRESS_WEBP_DECODER"]) if app_environment.key?("RAILPRESS_WEBP_DECODER")
        raise Error, "production_runtime_required" unless app_environment["RAILS_ENV"] == "production"
        origin = URI.parse(app_environment.fetch("RAILPRESS_HTTPS_ORIGIN"))
        raise Error, "isolated_origin" unless origin.scheme == "https" && origin.host == "localhost" && origin.port == data["edge_port"] && origin.path.empty? && !origin.userinfo && !origin.query && !origin.fragment
        raise Error, "proxy_peer_policy" unless app_environment["RAILPRESS_TLS_PROXY_IPS"] == "127.0.0.1"
        raise Error, "native_probe_secret" unless Releases::SHA.match?(app_environment["RAILPRESS_NATIVE_PROBE_TOKEN"].to_s)
        %w[RAILPRESS_PRIVATE_STATE_ROOT RAILPRESS_STORAGE_ROOT RAILPRESS_THEME_ROOT].each do |key|
          p = app_environment.fetch(key)
          raise Error, "persistent_root" unless p.start_with?(path("shared") + "/")
          F.directory!(p, private: true)
        end
        if app_environment.keys.any? { |key| key.start_with?("RAILPRESS_EXTENSION_") }
          namespace = { "w03_bridge" => "w03", "w03_restore" => "w03", "w04_recruitment" => "w04", "w04_recruitment_final" => "w04" }[data["test_database_profile"]]
          raise Error, "extension_native_scope" unless namespace && @root.start_with?("#{registry}/.local/state/#{namespace}/") &&
            app_environment["RAILPRESS_EXTENSION_ROOT"] == path("shared", "engines") &&
            app_environment["RAILPRESS_EXTENSION_SITE"] == data["install_id"] &&
            Releases::SEMVER.match?(app_environment["RAILPRESS_EXTENSION_CORE_ANCHOR"].to_s)
          F.directory!(path("shared", "engines"), private: true)
        end
        @registry = registry
      rescue URI::InvalidURIError, KeyError, Errno::ENOENT, TypeError
        raise Error, "native_configuration"
      end
      def path(*parts) = File.join(root, *parts)
      def release(id)
        Releases.identity!(id)
        F.directory!(path("releases", id))
      end
      def database!
        profile = data["test_database_profile"]
        file = File.join(@registry, ".local", "state", TestDatabase.registry_file(profile))
        stat = File.stat(file)
        raise Error, "private_database_registry" unless stat.uid == Process.uid && (stat.mode & 0o077).zero? && !File.symlink?(file)
        registry = NativeHost.load_document(file, maximum: 65_536)
        registry = registry.fetch(profile) if profile
        target = registry.fetch(data["engine"])
        raise Error, "synthetic_profile_identity" if profile && target["run_id"] != TestDatabase::PROFILES.fetch(profile)
        TestDatabase.validate!(target, environment: "test", confirmed: "railpress-synthetic-only")
        directory = File.realpath(target.fetch("data_directory"))
        raise Error, "synthetic_data_directory" unless directory.start_with?(File.join(@registry, ".local", "state") + "/") && File.stat(directory).uid == Process.uid
        expected = { "RAILPRESS_DB_ADAPTER" => "adapter", "RAILPRESS_DB_HOST" => "host", "RAILPRESS_DB_PORT" => "port",
          "RAILPRESS_DB_NAME" => "database", "RAILPRESS_DB_USER" => "username", "RAILPRESS_DB_PASSWORD" => "password" }
        raise Error, "configured_database_mismatch" unless expected.all? { |key, field| app_environment[key] == target[field].to_s } &&
          target["instance_id"] == data["database_instance_id"]
        identity = TestDatabase.verify!(target, environment: "test", confirmed: "railpress-synthetic-only")
        [ target, identity ]
      rescue TestDatabase::UnsafeTarget, KeyError, SystemCallError
        raise Error, "synthetic_database_unverified"
      end
      def runtime_environment(id, slot:)
        raise Error, "service_slot" unless [ 0, 1 ].include?(slot)
        release(id)
        profile_environment = data["test_database_profile"] ? { "RAILPRESS_NATIVE_TEST_PROFILE" => data["test_database_profile"] } : {}
        libraries = ENV.slice("LD_LIBRARY_PATH", "GEM_PATH", "GEM_HOME") if %w[w03_bridge w03_restore w03_reference w04_recruitment w04_recruitment_final].include?(data["test_database_profile"])
        app_environment.merge(profile_environment).merge(libraries || {}).merge("PATH" => File.dirname(data["ruby_binary"]) + ":/usr/bin:/bin",
          "HOME" => ENV.fetch("HOME"), "BUNDLE_GEMFILE" => path("releases", id, "Gemfile"),
          "DISABLE_BOOTSNAP" => "1", "RAILS_MAX_THREADS" => "5", "RAILS_LOG_LEVEL" => "warn",
          "RAILPRESS_DEPLOYMENT_DIGEST" => id, "RAILPRESS_DEPLOYMENT_ID" => data["deployment_id"],
          "RAILPRESS_NATIVE_PROFILE" => data["scope"], "RAILPRESS_NATIVE_TEST_REGISTRY" => data["registry_root"],
          "RAILPRESS_NATIVE_TEST_INSTANCE" => data["database_instance_id"], "RAILPRESS_NATIVE_INSTALL_ID" => data["install_id"],
          "PORT" => data["puma_ports"].fetch(slot).to_s,
          "PIDFILE" => File.join(app_environment.fetch("RAILPRESS_PRIVATE_STATE_ROOT"), "puma-#{slot}.pid"))
      end
      private
      def executable!(value, suffix: nil)
        raise Error, "native_executable" unless value.is_a?(String) && File.expand_path(value) == value && value.start_with?("/") &&
          (!suffix || value.end_with?(suffix)) && File.file?(value) && File.executable?(value) && !File.symlink?(value) &&
          (File.stat(value).mode & 0o022).zero?
      end
    end
  end
end
