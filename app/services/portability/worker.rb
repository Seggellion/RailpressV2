module Portability
  module Worker
    LEASE_SECONDS = 60
    module_function
    def lease_valid?(batch)
      value = batch.lease
      value.is_a?(Hash) && value["expires_at"].is_a?(Numeric) && Railpress::SecurityClock.for_application.valid?(value["binding"], expires_at: value["expires_at"], ttl: LEASE_SECONDS)
    end
    def lease
      deadline = Time.now.to_f + LEASE_SECONDS
      { "expires_at" => deadline, "binding" => Railpress::SecurityClock.for_application.issue(ttl: LEASE_SECONDS, expires_at: deadline) }
    end
    def claim!(batch)
      Authority.record_locked(batch) do |site, _actor, _session|
        return nil unless %w[staging activating reversing].include?(batch.state)
        return nil if batch.lease_token && lease_valid?(batch)
        state = PortabilityState.find_or_create_by!(site: site); state.lock!
        raise Imports::Conflict, "Another import owns the destination. Reconcile that batch first." if state.active_import_id && state.active_import_id != batch.id
        token = SecureRandom.hex(16)
        batch.update!(lease_token: token, lease: lease)
        state.update!(active_import: batch) unless state.active_import_id == batch.id
        ImportBatch.event!(batch, "worker_claimed", { "state" => batch.state })
        token
      end
    end
    def heartbeat!(batch)
      Authority.record_locked(batch) { Context.require!(batch); batch.update!(lease: lease) }
    end
    def perform!(batch, fault: nil)
      return Imports.inspect!(batch) if %w[queued inspecting].include?(batch.state)
      token = claim!(batch)
      return batch unless token
      Context.with(batch, token) do
        bytes = Store.read(batch); manifest, payloads = Railpress::SiteArchive.read(bytes); Format.check!(manifest, payloads)
        raise Format::Invalid, "journal_manifest_integrity" unless Imports.source_sha(manifest) == batch.normalized_sha256 && manifest == batch.manifest
        case batch.state
        when "staging"
          Imports.records(manifest).each do |kind, record|
            heartbeat!(batch)
            item = batch.import_items.find_by!(kind: kind, source_ref: record.fetch("ref"))
            Authority.record_locked(batch) do
              Context.require!(batch); item.lock!
              raise Format::Invalid, "journal_source_integrity" unless item.source_sha256 == Imports.source_sha(record)
              if %w[staged matched activated].include?(item.state)
                raise Imports::Conflict, "Staged record changed; retry cannot overwrite it." unless Fingerprint.current(item) == item.target_sha256
              else
                raise Format::Invalid, "journal_item_state" unless %w[planned processing].include?(item.state)
                reconcile_upload!(item) if item.kind == "media" && item.details["media_upload_id"]
                item.update!(state: "processing", details: item.details.merge("source_record" => record))
              end
            end
            next if %w[staged matched activated].include?(item.state)
            fault&.call("before_#{kind}", item)
            Stage.perform!(batch, item, record, payloads)
            fault&.call("after_#{kind}", item)
            Authority.record_locked(batch) do
              Context.require!(batch)
              batch.update!(progress: batch.import_items.where(state: %w[staged matched activated]).count)
              ImportBatch.event!(batch, "item_staged", { "kind" => kind, "ref" => item.source_ref, "created" => item.created_record })
            end
          end
          Authority.record_locked(batch) do |site, actor, _session|
            Context.require!(batch)
            if batch.decisions["appearance"] == "stage_compatible" && (appearance = manifest["appearance"]) && !batch.report["overlay_id"]
              package = ThemeInstallation.find_by!(site: site, status: "validated", theme_key: appearance["theme"], version: appearance["version"], digest: appearance["digest"])
              options = appearance["options"].merge(appearance["media"].to_h.to_h { |key, ref| [ key + "_id", Stage.target(batch, "media", ref) ] })
              overlay = Themes::Manager.overlay!(actor: actor, installation: package, attributes: options)
              batch.report = batch.report.merge("overlay_id" => overlay.id, "package_id" => package.id)
            end
            verify!(batch)
            batch.update!(state: "staged", failure: nil, lease: {}, lease_token: nil, report: batch.report.merge("reconciliation" => "all source hashes and destination fingerprints verified", "resume_state" => "staging"))
            release!(batch, site)
            ImportBatch.event!(batch, "staging_verified", { "records" => batch.import_items.count, "private" => true })
          end
        when "activating" then Activation.perform!(batch, fault: fault)
        when "reversing" then Reversal.perform!(batch, fault: fault)
        end
      end
      batch
    rescue Authority::Expired
      failure!(batch, "needs_approval", "approval_expired", token: token)
      raise
    rescue StandardError => error
      failure!(batch, "blocked", error.is_a?(Format::Invalid) ? error.message : error.class.name, token: token)
      raise
    end
    def failure!(batch, state, reason, token: nil)
      batch.with_lock do
        return if token && batch.lease_token != token
        prior = %w[staging activating reversing].include?(batch.state) ? batch.state : batch.report["resume_state"]
        batch.update!(state: state, failure: reason.to_s[0, 200], lease_token: nil, lease: {}, report: batch.report.merge("resume_state" => prior))
        ImportBatch.event!(batch, "worker_stopped", { "reason" => reason.to_s[0, 200], "resume_state" => prior })
      end
    end
    def reconcile_upload!(item)
      attempt = MediaUpload.lock.find_by(id: item.details["media_upload_id"])
      return unless attempt
      raise Format::Invalid, "unbound_accepted_media" if attempt.state == "accepted" && !item.target_id
      return if attempt.state == "accepted"
      Array(attempt.storage_keys).each { |key| MediaLibrary::Storage.delete_key!(key) }
      attempt.update!(state: "rejected", reason: "import_reconciled", storage_keys: [])
    end
    def verify!(batch)
      expected = Imports.records(batch.manifest)
      raise Format::Invalid, "journal_inventory_integrity" unless batch.import_items.where(kind: %w[author term media content revision menu]).count == expected.length
      expected.each do |kind, record|
        item = batch.import_items.find_by!(kind: kind, source_ref: record.fetch("ref"))
        raise Format::Invalid, "journal_source_integrity" unless item.source_sha256 == Imports.source_sha(record)
        raise Imports::Conflict, "A destination record changed or is missing: #{kind}." unless %w[staged matched activated].include?(item.state) && Fingerprint.current(item) == item.target_sha256
      end
      true
    end
    def release!(batch, site)
      state = PortabilityState.lock.find_by!(site: site)
      raise Imports::Conflict, "Destination claim changed." unless state.active_import_id == batch.id
      state.update!(active_import: nil)
    end
  end
end
