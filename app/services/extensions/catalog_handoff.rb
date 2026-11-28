# frozen_string_literal: true

module Extensions
  module CatalogHandoff
    Platform = Railpress::Extensions
    Invalid = Platform::Invalid
    TTL = 10.minutes.to_i
    REVIEW = :module_catalog_review
    REQUEST_SCOPE = "module_catalog_request"
    STATUS_MESSAGES = {
      "awaiting_operator" => "Awaiting operator installation",
      "verifying" => "The operator is verifying the exact package",
      "migrating" => "The operator is applying the reviewed migration plan",
      "restarting" => "The operator is verifying the restarted web and worker processes",
      "held" => "Installation held. Ask the site operator to inspect the request.",
      "failed" => "Installation failed. Ask the site operator to inspect the request.",
      "cancelled" => "Request cancelled",
      "retained" => "Package removed. Module data retained.",
      "recovery_required" => "Recovery required. Ask the site operator to reconcile the recorded phase."
    }.freeze
    REVIEW_ERRORS = {
      "extension_signature_expired" => "The staged catalog or package has expired. Ask the operator to refresh it.",
      "extension_key_revoked" => "The catalog or package publisher has been revoked. Ask the operator to review trust.",
      "module_catalog_offline" => "This catalog is unavailable. Ask the operator to stage the reviewed catalog.",
      "module_catalog_incompatible" => "This package needs a compatible Core and Extension API. Review the Core update procedure.",
      "module_catalog_clock" => "Host time could not be verified. Ask the operator to review the security clock.",
      "module_catalog_operator" => "Set up a supported module operator before requesting installation.",
      "module_catalog_package" => "The exact executable package is unavailable or incompatible. Ask the operator to stage it.",
      "module_catalog_dependencies" => "Install and enable the required module dependencies first."
    }.freeze
    module_function

    def identifiers(module_id, catalog_id)
      { "module" => Platform.id!(module_id), "catalog" => Platform.id!(catalog_id) }
    end

    def origin!(site, base_url)
      raise Invalid, "module_catalog_site_origin" unless Railpress::SiteOrigin.new(base_url).to_s == site.canonical_origin
    rescue Railpress::SiteOrigin::Invalid
      raise Invalid, "module_catalog_site_origin"
    end

    def sign_in_intent(site:, hints:)
      hints.merge("site" => site.install_id, "origin" => site.canonical_origin, "deadline" => deadline)
    end

    def sign_in_return(intent, site:, base_url:)
      return unless intent.is_a?(Hash) && intent.values_at("site", "origin") == [ site.install_id, site.canonical_origin ] && valid_deadline?(intent)
      origin!(site, base_url)
      identifiers(intent["module"], intent["catalog"])
    rescue Invalid
      nil
    end

    def review(hints, registry: Platform.registry)
      lock = registry.engine_set
      raise Invalid, "module_catalog_operator" unless lock && ENV["RAILPRESS_NATIVE_PROFILE"] == "isolated-synthetic-nginx-v1"
      instant = Railpress::SecurityClock.for_application.scheduling_instant
      raise Invalid, "module_catalog_clock" unless instant
      catalog = lock.staged_catalog(hints.fetch("catalog"), now: instant.to_i)
      row = catalog.entries.fetch(hints.fetch("module")) { raise Invalid, "module_catalog_offline" }
      raise Invalid, "module_catalog_incompatible" unless Platform::Catalog.compatible?(row)
      entry = package!(lock, row)
      enabled_dependencies = entry.manifest.dependencies.all? do |id, range|
        dependency = registry.entries[id]
        dependency && Platform::Manifest.includes_version?(range, dependency.version) && Activation.enabled?(id, registry: registry)
      end
      raise Invalid, "module_catalog_dependencies" unless enabled_dependencies
      [ catalog, row, entry ]
    end

    def package!(lock, row)
      entry = lock.review_staged_entry!(row.slice("id", "version", "package_sha256", "manifest_sha256"))
      fields = %w[name core extension_api license]
      unless row.values_at(*fields) == entry.manifest.data.values_at(*fields) && entry.plan_sha256 == row["plan_sha256"]
        raise Invalid, "module_catalog_package"
      end
      entry
    rescue Invalid => error
      raise if %w[extension_key_revoked extension_signature_expired].include?(error.message)
      raise Invalid, "module_catalog_package", cause: nil
    end

    def confirmation(site:, actor:, token:, hints:, catalog:, row:, registry: Platform.registry)
      selection = row.slice("version", "package_sha256", "manifest_sha256", "plan_sha256").merge(
        "operation" => "install", "request_key" => SecureRandom.uuid, "module_id" => row.fetch("id"),
        "engine_generation" => registry.generation, "engine_fingerprint" => registry.fingerprint,
        "activation_generation" => site_installation(site, row.fetch("id"))&.activation_generation || 0)
      value = hints.merge("identity" => identity(site, actor, token), "digest" => catalog.digest,
        "selection" => selection, "deadline" => deadline)
      verifier.generate(value, purpose: REVIEW)
    end

    def submit!(actor:, token:, confirmation:, base_url:)
      raise Invalid, "module_catalog_review" unless confirmation.is_a?(String) && confirmation.bytesize.between?(1, 4096)
      value = verifier.verified(confirmation, purpose: REVIEW)
      raise Invalid, "module_catalog_review" unless value.is_a?(Hash) && valid_deadline?(value)
      Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        origin!(site, base_url)
        unless value["identity"] == identity(site, actor, token) && UserSession.resolve(token)&.user_id == actor.id
          raise Invalid, "module_catalog_review"
        end
        hints = identifiers(value["module"], value["catalog"])
        catalog, row, = review(hints)
        selection = value.fetch("selection")
        fields = %w[version package_sha256 manifest_sha256 plan_sha256]
        unless value["digest"] == catalog.digest && selection["module_id"] == row["id"] && selection.values_at(*fields) == row.values_at(*fields)
          raise Invalid, "module_catalog_review"
        end
        operation = Requests.submit!(actor: actor, selection: selection)
        row_path = row.fetch("setup_path")
        PlatformState.find_or_create_by!(scope_name: REQUEST_SCOPE, key_name: operation.request_key) do |record|
          record.payload = { "site" => site.install_id, "path" => row_path, "catalog" => catalog.id, "digest" => catalog.digest }
        end
        operation
      end
    end

    def verify_operator_request!(operation, registry:)
      payload = request_context(operation)
      return unless payload
      unless payload["site"] == operation.site_identity && registry.site == operation.site_identity
        raise Invalid, "module_catalog_review"
      end
      catalog, row, = review(identifiers(operation.module_id, payload["catalog"]), registry: registry)
      fields = %w[version package_sha256 manifest_sha256 plan_sha256]
      unless catalog.digest == payload["digest"] && row.values_at(*fields) == operation.attributes.values_at(*fields)
        raise Invalid, "module_catalog_review"
      end
    end

    def request_context(operation)
      PlatformState.find_by(scope_name: REQUEST_SCOPE, key_name: operation.request_key)&.payload
    end

    def setup_path(operation)
      payload = request_context(operation)
      Platform::Catalog.setup_path!(operation.module_id, payload["path"]) if payload && payload["site"] == operation.site_identity
    rescue Invalid
      nil
    end

    def site_installation(site, id) = ExtensionInstallation.find_by(site: site, module_id: id)

    def identity(site, actor, token)
      [ site.install_id, site.canonical_origin, actor.id, actor.auth_version, Digest::SHA256.hexdigest(token.to_s), Railpress::Product::VERSION ]
    end

    def deadline
      now = Time.now
      Railpress::SecurityClock.for_application.issue(ttl: TTL, expires_at: now + TTL)
    end

    def valid_deadline?(value)
      binding = value["deadline"]
      binding.is_a?(Hash) && binding["wall_deadline"].is_a?(Numeric) &&
        Railpress::SecurityClock.for_application.valid?(binding, expires_at: Time.at(binding["wall_deadline"]), ttl: TTL)
    end

    def verifier = Rails.application.message_verifier(REVIEW)
  end
end
