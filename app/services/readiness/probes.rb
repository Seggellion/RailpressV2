require "nokogiri"
module Readiness
  module Probes
    module_function
    def cell(key, state, detail)
      { "key" => key, "state" => state, "detail" => detail }
    end
    def check(key)
      yield
    rescue StandardError => error
      Rails.logger.warn("Readiness #{key} unavailable (#{error.class.name})")
      cell(key, "ACTION REQUIRED", "The bounded local observation failed. Ask the operator to inspect private logs.")
    end
    def call(site)
      [
        check("installation") { cell("installation", Railpress::BootstrapState.for_application.installed? ? "HEALTHY" : "ACTION REQUIRED", "Private installation marker was checked for this assessment.") },
        cell("owner_recovery", "UNKNOWN", "Owner accounts exist; operator recovery and real mail delivery require separate recovery qualification."),
        check("database") { result = Site.connection_pool.with_connection { |c| c.select_value("SELECT 1") }; cell("database", result.to_i == 1 ? "HEALTHY" : "ACTION REQUIRED", "Adapter #{Site.connection.adapter_name}; a local SELECT 1 completed.") },
        check("theme") { theme(site) },
        check("assets") { assets },
        check("seo") { seo(site) },
        check("worker") { worker },
        check("security_time") { security_time },
        cell("mail", Identity::PasswordRecovery.mail_available? ? "UNKNOWN" : "ACTION REQUIRED", "Configuration is not delivery evidence. No external mail was sent; production delivery remains unverified."),
        check("storage") { storage },
        check("storage_capacity") { storage_capacity },
        check("storage_configuration") { storage_configuration },
        check("storage_processes") { storage_processes },
        check("official_news") { official_news },
        check("menus") { menus(site) },
        cell("updates", ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"].present? ? "UNKNOWN" : "UNSUPPORTED", "Native M11 inspect/stage requests require a separate operator, verified receipts and trusted UTC. Host activation requires a separately qualified M12 native profile and explicit operator approval; no remote feed is configured."),
        check("native_deployment") { native_deployment },
        cell("deployment_provider", "UNKNOWN", "Provider availability has not been measured. No deployment was attempted."),
        cell("backup_restore", "UNKNOWN", "Production backup/restore remains unverified. A separately attested disposable M12 rehearsal does not establish production RPO/RTO or provider availability."),
        check("origin_tls") { origin(site) },
        cell("qualification", "DEGRADED", "M05 historical clock/reliability and M08 valid-PNG child refusal remain open. Later hosting, recovery, CI and assistive qualification gates remain deferred.")
      ]
    end
    def native_deployment
      observation = Releases::HostStatus.read
      return cell("native_deployment", "UNKNOWN", "No fresh verified native observation exists; no deployment or restoration success is assumed.") unless observation && observation["verified"] && observation["fresh"]
      statement = observation.fetch("statement")
      healthy = statement["services_healthy"] == true && !statement["reconciliation_required"] && !statement["maintenance"]
      cell("native_deployment", healthy ? "HEALTHY" : "ACTION REQUIRED",
        "Disposable native observation: #{healthy ? 'matching proxy/application/worker' : 'reconciliation required'}; local restore rehearsal #{statement['restore_drill_completed'] ? 'attested' : 'pending'}. Production services, independent UTC, backups and provider availability remain unqualified.")
    end
    def origin(site, configured_origin: ENV["RAILPRESS_HTTPS_ORIGIN"] || ("https://localhost" if Rails.env.production?))
      if configured_origin && Railpress::SiteOrigin.new(configured_origin).to_s != site.canonical_origin
        return cell("origin_tls", "ACTION REQUIRED", "The operator HTTPS origin and site canonical origin differ. Reconcile both before claiming deployment readiness.")
      end
      cell("origin_tls", "UNKNOWN", "Origin configuration was compared where available; public reachability, certificate renewal and hosting availability are unverified.")
    end
    def theme(site)
      state = ThemeState.find_by(site: site)
      return cell("theme", "ACTION REQUIRED", "No validated theme is active. Core administration remains available.") unless state&.active_installation
      package = state.active_installation
      raise ArgumentError unless state.active_overlay&.theme_installation_id == package.id
      Themes::Storage.load(package)
      report = Themes::Smoke.call(Themes::Storage.path(package.theme_key, package.version, package.digest))
      raise ArgumentError unless report["digest"] == package.digest
      cell("theme", "HEALTHY", "Active API v1 package signature, files, overlay identity and bounded production smoke were checked locally.")
    end
    def assets
      if Rails.env.production?
        path = Rails.root.join("public/assets/.manifest.json")
        data = JSON.parse(File.binread(path, 2 * 1024 * 1024))
        %w[admin_shell.js admin.css].each do |key|
          row = data.fetch(key); file = Rails.root.join("public/assets", row.fetch("digested_path"))
          raise ArgumentError unless file.file? && file.realpath.to_s.start_with?(Rails.root.join("public/assets").realpath.to_s + "/")
        end
        cell("assets", "HEALTHY", "Compiled core administration assets exist in the local production manifest.")
      else
        cell("assets", "UNKNOWN", "Development assets are available; production compilation must be observed in production mode.")
      end
    end
    def seo(site)
      entries = Seo::UrlInventory.call(site: site)
      xml = Seo::SitemapCache.fetch(site: site).xml
      doc = Nokogiri::XML(xml) { |config| config.strict.nonet }
      urls = doc.xpath("//*[local-name()='loc']").map(&:text)
      raise ArgumentError unless urls.sort == entries.map(&:url).sort && urls.uniq == urls
      cell("seo", "HEALTHY", "Core canonical origin #{site.canonical_origin}; indexing #{site.indexing_enabled? ? 'enabled' : 'disabled'}. Offline public-policy inventory and sitemap agree; no live network claim.")
    end
    def security_time
      observation = Railpress::SecurityClock.for_application.sample
      if observation["anomaly"]
        cell("security_time", "DEGRADED", "A wall/boot-clock discontinuity was observed. Automated scheduled publication is held; committed public content remains available. The operator must independently verify UTC before clock reconciliation. Credentials retain boot-bound maximum lifetimes.")
      else
        cell("security_time", "UNKNOWN", "Boot-bound security deadlines are available; this does not prove UTC accuracy, future scheduling or native TLS time validity. Different-boot and legacy credentials require sign-in or reissue.")
      end
    end
    def worker
      record = SolidQueue::Process.where(kind: "Worker").order(last_heartbeat_at: :desc).first
      return cell("worker", "UNKNOWN", "No worker heartbeat has been observed in the configured local queue.") unless record
      age = Time.current - record.last_heartbeat_at
      cell("worker", age.between?(0, 60) ? "HEALTHY" : "DEGRADED", "A local worker heartbeat was observed; remote workers and future processing availability are not qualified.")
    end
    def storage
      service = MediaLibrary::Storage.ensure_private!
      if MediaLibrary::Storage.retained?(service)
        return cell("storage", "UNKNOWN", "Private GCS adapter configured; no provider was contacted. Object reads, effective IAM, lifecycle, versioning and soft-delete policy require separate qualification. Physical deletion is disabled; retained objects incur storage costs.")
      end
      return cell("storage", "UNKNOWN", "Remote storage was not contacted. A provider-specific availability check is still required.") unless service.is_a?(ActiveStorage::Service::DiskService)
      key = SecureRandom.hex(32)
      begin
        bytes = SecureRandom.random_bytes(32)
        service.upload(key, StringIO.new(bytes))
        raise IOError unless service.download(key) == bytes
      ensure
        service.delete(key) if key
      end
      cell("storage", "HEALTHY", "A new private local sentinel was written, read and deleted. This does not qualify production persistence or restore.")
    end
    def storage_configuration
      intent = MediaLibrary::Configuration.intent
      return cell("storage_configuration", "ACTION REQUIRED", "Legacy installation has no R8 storage binding. Operator review is required; no automatic media migration or backend switch is permitted.") unless intent
      report = MediaLibrary::Configuration.observe(intent)
      detail = report["cells"].map { |row| row["detail"] }.join(" ")
      cell("storage_configuration", report["state"], detail)
    end
    def storage_processes
      report = MediaLibrary::Configuration.agreement
      cell("storage_processes", report["state"], report["detail"])
    end
    def storage_capacity
      service=MediaLibrary::Storage.ensure_private!
      return cell("storage_capacity", "UNSUPPORTED", "Capacity requires a qualified local disk adapter; remote providers were not contacted.") unless service.is_a?(ActiveStorage::Service::DiskService)
      require "open3"
      require "timeout"
      output, status=Timeout.timeout(2) { Open3.capture2("df", "-PB1", "--", service.root.to_s) }
      raise IOError unless status.success?
      free=Integer(output.lines.last.split[3], 10)
      cell("storage_capacity", free.positive? ? "HEALTHY" : "ACTION REQUIRED", "Local filesystem observed #{free} bytes available. This is not a quota, durability or backup guarantee.")
    end
    def official_news
      view=OfficialNews::Cache.view(OfficialNewsState.find_by(site: Site.find_by!(singleton_key: 1)))
      status={ "FRESH"=>"HEALTHY", "LOCAL"=>"HEALTHY", "DISABLED"=>"UNSUPPORTED", "STALE"=>"DEGRADED", "DEGRADED"=>"DEGRADED" }.fetch(view["state"], "UNKNOWN")
      cell("official_news", status, "Optional public metadata: #{view['state']}. Local publishing does not depend on the provider.")
    end
    def menus(site)
      locations = MenuLocation.where(site: site).where.not(published_menu_id: nil).includes(published_menu: :published_revision)
      missing = 0
      locations.each do |location|
        revision = location.published_menu&.published_revision
        raise ArgumentError unless revision
        revision.snapshot.fetch("tree").each { |row| missing += 1 unless Navigation::Destinations.resolve(row, site) }
      end
      return cell("menus", "ACTION REQUIRED", "No published theme location is assigned. Publish and assign a menu if navigation is needed.") if locations.empty?
      cell("menus", missing.zero? ? "HEALTHY" : "DEGRADED", "#{locations.size} published locations checked; #{missing} unavailable destinations are omitted by the public renderer.")
    end
  end
end
