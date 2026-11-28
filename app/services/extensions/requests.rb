# frozen_string_literal: true

module Extensions
  module Requests
    Platform = Railpress::Extensions
    Invalid = Platform::Invalid
    CORE_SWITCH_OPERATIONS = %w[promote revert].freeze
    ACTIVE_OPERATOR_STATES = %w[verifying migrating restarting].freeze
    CORE_SWITCH_TERMINAL = %w[ACTIVE PREVIOUS_ACTIVE FAILED_STAGED].freeze
    TRANSITIONS = {
      "awaiting_operator" => %w[verifying held failed cancelled],
      "verifying" => %w[migrating restarting held failed cancelled],
      "migrating" => %w[restarting held failed recovery_required],
      "restarting" => %w[installed retained held recovery_required],
      "held" => %w[recovery_required cancelled],
      "recovery_required" => []
    }.freeze
    module_function

    def submit!(actor:, selection:, registry: Platform.registry)
      fields = validate_selection!(selection)
      Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        fresh = locked_owner!(actor.id, actor.auth_version)
        if registry.site && registry.site != site.install_id
          raise Invalid, "extension_site_identity"
        end
        binding = fields.merge("site_id" => site.id, "site_identity" => site.install_id, "site_origin" => site.canonical_origin,
          "actor_id" => fresh.id, "actor_auth_version" => fresh.auth_version, "core_version" => Railpress::Product::VERSION)
        previous = ExtensionInstallRequest.find_by(request_key: fields["request_key"])
        if previous
          raise Invalid, "extension_request_conflict" unless previous.attributes.slice(*binding.keys) == binding
          next previous
        end
        raise Invalid, "extension_request_pending" if pending?(site)
        raise Invalid, "extension_core_switch_pending" if core_switch_pending?(site)
        raise Invalid, "extension_engine_generation" unless fields["engine_generation"] == registry.generation &&
          fields["engine_fingerprint"] == registry.fingerprint
        installation = ExtensionInstallation.find_by(site: site, module_id: fields["module_id"])
        raise Invalid, "extension_activation_stale" unless fields["activation_generation"] == (installation&.activation_generation || 0)
        validate_operation!(fields, installation)
        request = ExtensionInstallRequest.create!(binding.merge("state" => "awaiting_operator"))
        audit!(fresh, request, "requested")
        request
      end
    end

    def cancel!(actor:, request_key:)
      Platform.uuid!(request_key)
      Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        fresh = locked_owner!(actor.id, actor.auth_version)
        request = ExtensionInstallRequest.lock.find_by!(site: site, request_key: request_key)
        unless request.state == "awaiting_operator" && request.receipt_sequence.zero?
          raise Invalid, "extension_cancel_after_operator"
        end
        request.update!(state: "cancelled")
        audit!(fresh, request, "cancelled")
        request
      end
    end

    def accept!(request_key:, envelope:, registry: Platform.registry)
      Platform.uuid!(request_key)
      raise Invalid, "extension_operator_unconfigured" unless registry.trust
      now = Time.now.to_i
      statement = registry.trust.verify!(envelope, purpose: Platform::Trust::RECEIPT, now: now)
      validate_receipt!(statement, now)
      receipt_sha = Digest::SHA256.hexdigest(envelope)
      Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        request = ExtensionInstallRequest.lock.find_by!(site: site, request_key: request_key)
        fresh = locked_owner!(request.actor_id, request.actor_auth_version)
        validate_binding!(statement, site, request, registry)
        sequence = statement["sequence"]
        if sequence == request.receipt_sequence && request.receipt_sha256 == receipt_sha
          next request
        end
        raise Invalid, "extension_receipt_replay" unless sequence > request.receipt_sequence
        state = statement["state"]
        raise Invalid, "extension_receipt_transition" unless TRANSITIONS.fetch(request.state, []).include?(state)
        if state != "recovery_required" && ExtensionMigrationRecord.exists?(site: site, module_id: request.module_id, state: %w[started recovery_required])
          raise Invalid, "extension_migration_recovery_required"
        end
        if %w[installed retained].include?(state)
          finish!(site, request, statement, registry)
        else
          validate_progress_lock!(request, statement, registry)
          if state == "verifying"
            installation = ExtensionInstallation.lock.find_by(site: site, module_id: request.module_id)
            validate_current_installation!(request, installation)
          end
        end
        request.update!(state: state, receipt_sequence: sequence, receipt_sha256: receipt_sha,
          operator_receipt: Railpress::Releases.parse(envelope, limit: Platform::Trust::LIMIT))
        audit!(fresh, request, "operator_status")
        request
      end
    end

    def request_digest(request) = Platform.digest(request.attributes.slice(*ExtensionInstallRequest::IDENTITY_FIELDS))

    def pending?(site) = ExtensionInstallRequest.exists?(site: site, state: ExtensionInstallRequest::PENDING)

    def core_switch_pending?(site)
      ReleaseRequest.where(site: site, operation: CORE_SWITCH_OPERATIONS).any? do |request|
        receipt = ::Releases::Requests.receipt_for(request)
        receipt.nil? || !CORE_SWITCH_TERMINAL.include?(receipt["state"])
      end
    end

    def locked_owner!(id, auth_version)
      fresh = User.lock.find_by(id: id)
      Identity::Capabilities.require!(fresh, :manage_modules)
      raise Identity::Capabilities::Denied unless fresh.auth_version == auth_version
      fresh
    end

    def validate_selection!(selection)
      fields = %w[request_key operation module_id version package_sha256 manifest_sha256 plan_sha256 engine_generation engine_fingerprint activation_generation]
      Railpress::Releases.keys!(selection, fields)
      Platform.uuid!(selection["request_key"])
      Platform.id!(selection["module_id"])
      Platform.version!(selection["version"])
      raise Invalid, "extension_operation" unless ExtensionInstallRequest::OPERATIONS.include?(selection["operation"])
      %w[package_sha256 manifest_sha256 plan_sha256 engine_fingerprint].each { |key| Railpress::Releases.identity!(selection[key]) }
      %w[engine_generation activation_generation].each { |key| Platform.generation!(selection[key]) }
      selection
    end

    def validate_operation!(fields, installation)
      installed = installation&.package_state == "installed"
      case fields["operation"]
      when "install"
        raise Invalid, "extension_already_installed" if installed
      when "upgrade", "revert"
        raise Invalid, "extension_not_installed" unless installed
        direction = fields["operation"] == "upgrade" ? 1 : -1
        unless Railpress::Releases.compare_versions(fields["version"], installation.version) == direction
          raise Invalid, "extension_version_direction"
        end
      when "uninstall"
        unless installed && !installation.enabled && fields.values_at(*%w[version package_sha256 manifest_sha256]) ==
            installation.attributes.values_at(*%w[version package_sha256 manifest_sha256])
          raise Invalid, "extension_disable_before_uninstall"
        end
      end
    end

    def validate_receipt!(statement, now)
      Railpress::Releases.keys!(statement, %w[format id request_sha256 sequence issued_at expires_at state engine_generation engine_fingerprint processes module_schema job_revision retention_clear])
      Railpress::Releases.identity!(statement["request_sha256"])
      Railpress::Releases.identity!(statement["engine_fingerprint"])
      Platform.generation!(statement["engine_generation"])
      issued = Platform.generation!(statement["issued_at"], minimum: 1)
      raise Invalid, "extension_receipt_time" unless issued.between?(now - 300, now) && statement["expires_at"].between?(issued + 1, issued + 300)
      raise Invalid, "extension_receipt_retention" unless [ true, false ].include?(statement["retention_clear"])
    end

    def validate_binding!(statement, site, request, registry)
      unless registry.site == site.install_id && request.site_identity == site.install_id && request.site_origin == site.canonical_origin &&
          request.core_version == Railpress::Product::VERSION && statement["request_sha256"] == request_digest(request) &&
          statement["id"] == request.module_id
        raise Invalid, "extension_receipt_binding"
      end
    end

    def validate_progress_lock!(request, statement, registry)
      unless statement.values_at("processes", "module_schema", "job_revision", "retention_clear") == [ nil, nil, nil, false ] &&
          statement["engine_generation"] == registry.generation && statement["engine_fingerprint"] == registry.fingerprint &&
          (current_lock?(request, registry) || successor_lock?(request, registry))
        raise Invalid, "extension_progress_identity"
      end
    end

    def current_lock?(request, registry)
      request.engine_generation == registry.generation && request.engine_fingerprint == registry.fingerprint
    end

    def successor_lock?(request, registry)
      lock = registry.engine_set
      lock && request.engine_generation == lock.previous_generation && request.engine_fingerprint == lock.previous_fingerprint
    end

    def finish!(site, request, statement, registry)
      unless successor_lock?(request, registry) && statement["engine_generation"] == registry.generation &&
          statement["engine_fingerprint"] == registry.fingerprint
        raise Invalid, "extension_receipt_lock"
      end
      verify_processes!(statement, registry)
      row = ExtensionInstallation.lock.find_or_initialize_by(site: site, module_id: request.module_id)
      validate_current_installation!(request, row)
      state = request.operation == "uninstall" ? "retained" : "installed"
      raise Invalid, "extension_receipt_outcome" unless statement["state"] == state
      entry = registry.entries[request.module_id]
      if state == "retained"
        raise Invalid, "extension_retention_hold" unless entry.nil? && statement["retention_clear"] &&
          statement.values_at("module_schema", "job_revision") == [ row.module_schema, row.job_revision ]
      else
        installed_package!(entry, site, request, statement, row)
      end
      rebind_other_installations!(site, request, registry)
      row.update!(version: request.version, package_sha256: request.package_sha256, manifest_sha256: request.manifest_sha256,
        package_state: state, enabled: false, activation_generation: request.activation_generation + 1, engine_generation: registry.generation,
        engine_fingerprint: registry.fingerprint, module_schema: statement["module_schema"], job_revision: statement["job_revision"])
    end

    def validate_current_installation!(request, installation)
      unless (installation&.activation_generation || 0) == request.activation_generation
        raise Invalid, "extension_activation_stale"
      end
      validate_operation!(request.attributes, installation)
    end

    def verify_processes!(statement, registry)
      processes = statement["processes"]
      Railpress::Releases.keys!(processes, %w[web worker])
      processes.each_value do |process|
        Railpress::Releases.keys!(process, %w[pid fingerprint healthy])
        Railpress::Releases.integer!(process["pid"], 1, 2**31 - 1)
        unless process["healthy"] == true && process["fingerprint"] == registry.fingerprint
          raise Invalid, "extension_process_identity"
        end
      end
      raise Invalid, "extension_process_identity" if processes["web"]["pid"] == processes["worker"]["pid"]
    end

    def installed_package!(entry, site, request, statement, row)
      unless entry && request.version == entry.version && request.package_sha256 == entry.package_sha256 &&
          request.manifest_sha256 == entry.manifest.digest && request.plan_sha256 == entry.plan_sha256
        raise Invalid, "extension_receipt_package"
      end
      contract = entry.manifest.data_contract
      schema = statement["module_schema"]
      jobs = statement["job_revision"]
      compatible = ->(kind, number) { Platform::Manifest.includes_number?(contract.fetch(kind), number) }
      unless compatible.call("schema_read", schema) && compatible.call("schema_write", schema) &&
          compatible.call("jobs_read", jobs) && compatible.call("jobs_write", jobs) &&
          (!row.persisted? || (schema >= row.module_schema && compatible.call("schema_read", row.module_schema) &&
            compatible.call("jobs_read", row.job_revision))) &&
          Platform::Migrations.applied?(site: site, entry: entry)
        raise Invalid, "extension_data_or_jobs_window"
      end
    end

    def rebind_other_installations!(site, request, registry)
      others = ExtensionInstallation.lock.where(site: site, package_state: "installed").where.not(module_id: request.module_id)
      expected = request.operation == "uninstall" ? registry.entries.keys : registry.entries.keys - [ request.module_id ]
      raise Invalid, "extension_unrelated_selection" unless others.map(&:module_id).sort == expected.sort
      others.each do |row|
        entry = registry.entries.fetch(row.module_id)
        unless row.engine_generation == request.engine_generation && row.engine_fingerprint == request.engine_fingerprint &&
            [ row.version, row.package_sha256, row.manifest_sha256 ] == [ entry.version, entry.package_sha256, entry.manifest.digest ]
          raise Invalid, "extension_unrelated_selection"
        end
        row.update!(engine_generation: registry.generation, engine_fingerprint: registry.fingerprint)
      end
    end

    def audit!(actor, request, verb)
      Activity::Recorder.record!(actor: actor, action: "extension.#{verb}",
        details: { operation: request.operation, digest: request.package_sha256, state: request.state })
    end
  end
end
