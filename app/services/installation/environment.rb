# frozen_string_literal: true

module Installation
  module Environment
    module_function

    def cell(key, state, detail) = { "key" => key, "state" => state, "detail" => detail }

    def candidate
      path = ENV["RAILPRESS_INSTALL_THEME"]
      raise Progress::Invalid, "The operator must stage the trusted Dusk installation package." unless path && File.directory?(path) && File.absolute_path(path) == path && !File.symlink?(path)
      root = ENV["RAILPRESS_THEME_ROOT"]
      raise Progress::Invalid, "The operator must provision private persistent theme storage." unless root && File.directory?(root)
      bundle = Railpress::ThemePackage.load(path, trusted_keys: Themes::Storage.trusted_keys)
      raise Progress::Invalid, "The default installation package must be Dusk." unless bundle.manifest["id"] == "dusk"
      bundle
    end

    def call
      results = []
      results << cell("runtime", Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.4.0") ? "HEALTHY" : "ACTION REQUIRED", "Railpress #{Railpress::Product::VERSION}; native Ruby #{RUBY_VERSION}; Rails #{Rails.version}.")
      begin
        Process.clock_gettime(Process::CLOCK_BOOTTIME)
        raise IOError if File.read("/proc/sys/kernel/random/boot_id").strip.empty?
        File.readlink("/proc/self/ns/time")
        results << cell("security_time", "HEALTHY", "Linux boot/time-domain and suspend-aware clock are readable. This does not qualify UTC accuracy or native TLS time validity.")
      rescue StandardError, NotImplementedError
        results << cell("security_time", "ACTION REQUIRED", "A qualified native Linux boot-domain and suspend-aware clock are required for credentials. Ask the operator to check host support.")
      end
      begin
        require "vips"
        results << cell("images", "HEALTHY", "Native image library #{Vips.version_string} is loaded. Upload safety remains separately enforced.")
      rescue LoadError, StandardError
        results << cell("images", "ACTION REQUIRED", "The operator must install the supported native image dependencies.")
      end
      path = Railpress::BootstrapState.for_application.root
      private_ok = private_directory?(path) && (!Rails.env.production? || (ENV["RAILPRESS_PRIVATE_STATE_ROOT"].present? && outside_release?(path)))
      results << cell("private_state", private_ok ? "HEALTHY" : "ACTION REQUIRED", "Private setup directory ownership and write permission inspected. Production requires an explicit path outside the release; volume durability remains operator-qualified.")
      if Rails.env.production? && ENV["RAILPRESS_STORAGE_BACKEND"] == "gcs"
        quarantine = ENV["RAILPRESS_QUARANTINE_ROOT"]
        local_ok = private_directory?(quarantine) && outside_release?(quarantine) && ENV["RAILPRESS_GCS_BUCKET"].present? && ENV["RAILPRESS_GCS_PROJECT"].present?
        results << cell("media_storage", local_ok ? "HEALTHY" : "ACTION REQUIRED", "GCS requires explicit host bucket/project and private local quarantine outside releases. This result checks local prerequisites only; no provider was contacted.")
        results << cell("gcs_provider", "UNKNOWN", "Before storing valuable data qualify GCS private access, scoped IAM, immutable writes, retained objects and recovery. Uploads refuse buckets without uniform access and enforced public-access prevention. No live-provider qualification is inferred from setup.")
      else
        media = Rails.env.test? ? Rails.root.join(".local/state/media/test", ENV.fetch("RAILPRESS_TEST_ENGINE")).to_s : ENV["RAILPRESS_STORAGE_ROOT"]
        media_ok = private_directory?(media) && (!Rails.env.production? || outside_release?(media))
        results << cell("media_storage", media_ok ? "HEALTHY" : "ACTION REQUIRED", "Private media directory ownership and write permission inspected. Capacity, actual upload and host durability require separate verification. Persistent Disk recovery is outside the initial alpha qualified recovery profile.")
      end
      begin
        origin = Configuration.canonical_origin
        results << cell("origin", "HEALTHY", "Fixed operator HTTPS origin: #{origin}. Reachability and renewal are not measured.")
      rescue StandardError
        results << cell("origin", "ACTION REQUIRED", "The operator must configure the fixed HTTPS origin.")
      end
      begin
        bundle = candidate
        results << cell("dusk", "HEALTHY", "Operator-trusted Dusk #{bundle.manifest['version']} signature, manifest and files verified. Runtime smoke follows before activation.")
      rescue StandardError
        results << cell("dusk", "ACTION REQUIRED", "A validated, operator-trusted signed Dusk package and persistent storage are required. Illustrated packages also require the supported native static-WebP decoder configured by the operator.")
      end
      begin
        assets = Readiness::Probes.assets
        results << assets.merge("state" => Rails.env.production? ? assets["state"] : "UNKNOWN")
      rescue StandardError
        results << cell("assets", "ACTION REQUIRED", "The operator must compile and retain production assets.")
      end
      results << cell("worker", "UNKNOWN", "The worker is gated until installation. Its actual heartbeat is checked after setup; operator provisioning is required.")
      results << cell("mail", "UNKNOWN", "No mail was sent. Configure and verify owner recovery before public service.")
      results << cell("hosting_backup", "UNKNOWN", "Provider, persistent media, TLS renewal and backup/restore are not production-qualified by local setup.")
      results
    end

    def outside_release?(path)
      actual = File.realpath(path)
      root = Rails.root.realpath.to_s
      actual != root && !actual.start_with?(root + "/")
    end

    def private_directory?(path)
      return false unless path && File.directory?(path) && File.realpath(path) == path.to_s
      stat = File.lstat(path)
      stat.uid == Process.uid && (stat.mode & 0o077).zero? && File.writable?(path)
    end

    def required_ready?(cells)
      %w[runtime security_time images private_state origin dusk].all? { |key| cells.any? { |row| row["key"] == key && row["state"] == "HEALTHY" } } &&
        (!Rails.env.production? || cells.any? { |row| row["key"] == "assets" && row["state"] == "HEALTHY" })
    end
  end
end
