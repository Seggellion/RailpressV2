# frozen_string_literal: true

require "socket"

module MediaLibrary
  module Configuration
    class Handoff < StandardError; end
    SCOPE = "media_configuration"
    TTL = 180
    module_function

    def host_environment
      Rails.env.test? ? ENV.to_h : Rails.application.config.x.railpress_media_environment
    end

    def runtime
      service = ActiveStorage::Blob.service
      env = host_environment
      if Rails.env.test?
        if service.is_a?(ActiveStorage::Service::DiskService)
          return Railpress::MediaConfiguration.selection({ "backend" => "local" }, disk_root: service.root.to_s)
        elsif service.respond_to?(:store)
          store = service.store
          return Railpress::MediaConfiguration.selection({ "backend" => "gcs", "project" => store.project, "bucket" => store.bucket_name,
            "prefix" => store.prefix, "auth_method" => store.auth_method, "identity_source" => store.identity_source })
        end
      end
      Railpress::MediaConfiguration.environment(env, disk_root: env.fetch("RAILPRESS_STORAGE_ROOT", ""))
    end

    def selection(fields)
      root = host_environment.fetch("RAILPRESS_STORAGE_ROOT", "")
      root = ActiveStorage::Blob.service.root.to_s if Rails.env.test? && ActiveStorage::Blob.service.is_a?(ActiveStorage::Service::DiskService)
      Railpress::MediaConfiguration.selection(fields, disk_root: root)
    end

    def intent
      PlatformState.uncached { PlatformState.find_by(scope_name: SCOPE, key_name: "intent")&.payload }
    end

    def install!(value)
      assert_applied!(value)
      raise Handoff, "Storage intent already exists; reconcile the installation without switching media." if intent
      PlatformState.create!(scope_name: SCOPE, key_name: "intent", payload: Railpress::MediaConfiguration.validate!(value))
    end

    def fingerprint
      env = host_environment
      locator = env["RAILPRESS_GCS_CREDENTIALS_FILE"] || Railpress::MediaConfiguration.adc_path(env) || "ADC metadata discovery"
      locator = "attached ADC" if runtime["identity_source"] == "attached"
      Digest::SHA256.hexdigest(JSON.generate([ runtime.sort.to_h, env.fetch("RAILPRESS_STORAGE_CONFIG_EPOCH", "1"), Digest::SHA256.hexdigest(locator) ]))
    end

    def directory?(path)
      path.is_a?(String) && File.directory?(path) && File.realpath(path) == path && File.stat(path).uid == Process.uid && (File.stat(path).mode & 0o077).zero? && File.writable?(path) &&
        (!Rails.env.production? || (path != Rails.root.realpath.to_s && !path.start_with?(Rails.root.realpath.to_s + "/")))
    rescue SystemCallError
      false
    end

    def observe(selected = nil, probe_disk: false)
      active = runtime
      selected ||= active
      Railpress::MediaConfiguration.validate!(selected)
      result = { "intended" => selected, "effective" => active, "state" => "CONFIGURED", "cells" => [] }
      if selected != active
        result["state"] = "ACTION REQUIRED"
        result["cells"] << { "key" => "handoff", "state" => "ACTION REQUIRED", "detail" => "Choice saved. Ask the operator to apply the matching host configuration and restart web and worker processes. No host file or process was changed by this form." }
        return result
      end
      if active["backend"] == "gcs"
        require "google/cloud/storage"
        credentials = Railpress::MediaConfiguration.credential_status(active, env: host_environment)
        result["cells"] << credentials.merge("key" => "credentials")
        local = directory?(host_environment["RAILPRESS_QUARANTINE_ROOT"])
        result["cells"] << { "key" => "private_processing", "state" => local ? "CONFIGURED" : "ACTION REQUIRED", "detail" => "A private local processing directory outside releases is required even when media lives in GCS." }
        service = ActiveStorage::Blob.service
        matches = service.respond_to?(:store) && service.store.bucket_name == active["bucket"] && service.store.project == active["project"] && service.store.prefix == active["prefix"] && service.store.auth_method == active["auth_method"]
        result["cells"] << { "key" => "adapter", "state" => matches ? "CONFIGURED" : "ACTION REQUIRED", "detail" => "The running adapter must match the selected host configuration. Changing environment files requires process restart." }
        result["state"] = "ACTION REQUIRED" unless local && matches && credentials["state"] == "CONFIGURED"
        result["cells"] << { "key" => "provider", "state" => "NOT TESTED", "detail" => "No cloud request was made. Bucket identity, upload/read permissions, effective IAM, private access and actual retention need an authorized disposable-provider check. No delete permission or physical cleanup is required by Railpress." }
      else
        root = active["disk_root"]
        safe = directory?(root) && ActiveStorage::Blob.service.is_a?(ActiveStorage::Service::DiskService) && ActiveStorage::Blob.service.root.to_s == root
        result["state"] = "ACTION REQUIRED" unless safe
        result["cells"] << { "key" => "directory", "state" => safe ? "CONFIGURED" : "ACTION REQUIRED", "detail" => "Configured directory: #{root}. Ownership, private permissions and writability are checked locally; volume durability is not inferred." }
        if safe && probe_disk
          service = ActiveStorage::Blob.service
          key = SecureRandom.hex(32)
          begin
            bytes = SecureRandom.random_bytes(32)
            service.upload(key, StringIO.new(bytes))
            raise Handoff unless service.download(key) == bytes
            result["cells"] << { "key" => "disk_io", "state" => "VERIFIED", "detail" => "One new private sentinel was written, read and removed. This verifies local I/O, not persistence or recovery." }
          ensure
            service.delete(key)
          end
        end
        result["cells"] << { "key" => "durability", "state" => "NOT TESTED", "detail" => "The operator must verify a persistent volume outside releases and its backup plan. Ephemeral or unknown storage is unsuitable for valuable media. Persistent Disk recovery remains unqualified." }
      end
      result
    rescue Railpress::MediaConfiguration::Invalid, SystemCallError, IOError, Handoff, LoadError
      { "state" => "ACTION REQUIRED", "cells" => [ { "key" => "configuration", "state" => "ACTION REQUIRED", "detail" => "The selected storage configuration or private local prerequisite is unavailable. Review the operator guide. No alternate endpoint or credential fallback was attempted." } ] }
    end

    def assert_applied!(selected)
      raise Handoff, "Media storage needs operator attention. Return to Media Storage, apply the selected configuration and restart the required processes." unless observe(selected)["state"] == "CONFIGURED"
      true
    end

    def guard!
      value = intent
      return true unless value # Existing pre-R8 installations remain explicitly legacy/unbound.
      raise Handoff, "Storage configuration drift; media switching requires a separately qualified migration." unless value == runtime
      true
    end

    def record_worker!
      return false unless ENV["RAILPRESS_PROCESS_ROLE"] == "worker"
      registrations = SolidQueue::Process.uncached { SolidQueue::Process.where(kind: "Worker", pid: Process.pid, hostname: Socket.gethostname).pluck(:id) }
      return false if registrations.empty?
      Site.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        row = PlatformState.find_or_initialize_by(scope_name: SCOPE, key_name: "worker")
        reports = (row.payload || {}).fetch("reports", {}).slice(*active_workers.map { |worker| worker.id.to_s })
        registrations.each do |id|
          reports[id.to_s] = { "fingerprint" => fingerprint, "install_id" => site.install_id, "pid" => Process.pid,
            "binding" => Railpress::SecurityClock.for_application.issue(ttl: TTL, expires_at: Time.now + TTL) }
        end
        row.payload = { "version" => 1, "reports" => reports }
        row.save!
      end
      true
    end

    def active_workers
      SolidQueue::Process.uncached { SolidQueue::Process.where(kind: "Worker").order(:id).to_a }.select do |worker|
        next true unless worker.hostname == Socket.gethostname
        begin
          Process.kill(0, worker.pid)
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end
      end
    end

    def worker_identity
      reports = PlatformState.uncached { PlatformState.find_by(scope_name: SCOPE, key_name: "worker")&.payload }&.fetch("reports", {}) || {}
      install_id = Site.find_by(singleton_key: 1)&.install_id
      return [] unless install_id
      active_workers.map do |worker|
        data = reports[worker.id.to_s] || {}
        binding = data["binding"]
        fresh = worker.hostname == Socket.gethostname && data["pid"] == worker.pid && data["install_id"] == install_id &&
          binding.is_a?(Hash) && binding["wall_deadline"].is_a?(Numeric) && Railpress::SecurityClock.for_application.valid?(binding, expires_at: Time.at(binding["wall_deadline"]), ttl: TTL)
        # Renewal alone does not invalidate readiness; registration, configuration
        # changes and boot-domain expiry do. Unknown remote workers stay unverified.
        [ worker.id, data["fingerprint"], data["install_id"], fresh ]
      end
    end

    def agreement
      workers = worker_identity
      mismatch = workers.any? { |_, value, _, fresh| fresh && value != fingerprint }
      return { "state" => "ACTION REQUIRED", "detail" => "Web and worker configuration differ. Apply the intended settings and restart all processes; no automatic media switch was performed." } if mismatch
      return { "state" => "NOT TESTED", "detail" => "An actual worker storage observation is missing, stale or outside this native host. Start/restart every worker and run Site Readiness. GCS is not verified active on all processes." } if workers.empty? || workers.any? { |_, _, _, fresh| !fresh }
      { "state" => "CONFIGURED", "detail" => "Web and every currently registered live local queue worker reported the same configuration, source locator and operator epoch. This does not verify cloud principal, IAM or provider operations. Multi-host worker agreement is not qualified." }
    end
  end
end
