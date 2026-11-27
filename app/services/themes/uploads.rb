# frozen_string_literal: true

module Themes
  module Uploads
    INVALID = Railpress::ThemePackage::Invalid
    module_function

    def submit!(actor:, input:)
      raise INVALID, "zip_required" unless input.respond_to?(:tempfile) && input.tempfile.respond_to?(:read)
      key = SecureRandom.uuid
      record = Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        owner = current_owner!(actor.id, actor.auth_version)
        raise Manager::Conflict, "upload_pending" if site_uploads(site).where(state: %w[queued validating staging]).exists?
        size, digest = UploadStorage.save!(key, input.tempfile)
        record = site_uploads(site).create!(operation_key: key, actor_id: owner.id, actor_auth_version: owner.auth_version,
          byte_size: size, transport_sha256: digest, state: "queued")
        Activity::Recorder.record!(actor: owner, action: "theme.upload", details: { state: record.state, digest: digest })
        record
      end
      enqueue(record)
    end

    def resume!(actor:, id:)
      record = UploadStorage.with_validator do
        Site.transaction do
          site = Site.lock.find_by!(singleton_key: 1)
          owner = current_owner!(actor.id, actor.auth_version)
          upload = site_uploads(site).lock.find(id)
          raise Manager::Protected, "upload_owner_changed" unless upload.actor_id == owner.id && upload.actor_auth_version == owner.auth_version
          raise Manager::Conflict, "upload_state_changed" unless ThemeUpload::RESUMABLE.include?(upload.state)
          if site_uploads(site).where(state: %w[queued validating staging]).where.not(id: upload.id).exists?
            raise Manager::Conflict, "upload_pending"
          end
          upload.update!(state: "queued", result_code: nil)
          upload
        end
      end
      enqueue(record)
    end

    def enqueue(record)
      job = ValidateThemeUploadJob.perform_later(record.id)
      record.update!(state: "held", result_code: "queue_unavailable") unless job
      record
    rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError, ActiveRecord::ActiveRecordError
      ThemeUpload.where(id: record.id, state: "queued").update_all(state: "held", result_code: "queue_unavailable")
      record.reload
    end

    def perform!(id)
      UploadStorage.with_validator do
        upload = ThemeUpload.find_by(id: id)
        next unless upload && %w[queued validating staging].include?(upload.state)
        validate!(upload)
      end
    rescue UploadStorage::Unavailable => error
      # A duplicate delivery never steals ownership from a live validator.
      if error.message != "validator_busy"
        ThemeUpload.where(id: id, state: "queued").update_all(state: "held", result_code: "validator_unavailable")
      end
    end

    def validate!(upload)
      owner = User.find_by(id: upload.actor_id)
      raise Manager::Protected, "upload_owner_changed" unless owner&.owner? && owner.auth_version == upload.actor_auth_version
      upload.update!(state: "validating", result_code: nil)
      UploadStorage.with_extracted(upload) do |directory|
        bundle = Railpress::ThemePackage.load(directory, trusted_keys: Storage.trusted_keys)
        publisher = Publishers.verify!(bundle)
        if ThemeInstallation.where(site_id: upload.site_id, theme_key: bundle.manifest["id"], version: bundle.manifest["version"])
            .where.not(digest: bundle.digest).exists?
          raise INVALID, "theme_version_digest_conflict"
        end
        if upload.manifest_sha256 && upload.manifest_sha256 != bundle.digest
          raise UploadStorage::Unavailable, "staged_digest_changed"
        end
        report = Smoke.call(directory)
        upload.update!(state: "staging", manifest_sha256: bundle.digest)
        Manager.stage_upload!(actor: owner, upload: upload, bundle: bundle, publisher: publisher, report: report)
      end
      remove_terminal_archive(upload)
    rescue INVALID => error
      finish_failure(upload, "rejected", error.message)
      remove_terminal_archive(upload)
    rescue Manager::Conflict, Manager::Protected, UploadStorage::Unavailable, Activity::Recorder::Unavailable, ActiveRecord::ActiveRecordError, SystemCallError
      finish_failure(upload, "held", "validation_held")
    end

    def remove_terminal_archive(upload)
      UploadStorage.remove!(upload.operation_key)
    rescue UploadStorage::Unavailable
      Rails.logger.warn("Theme upload archive retained after terminal result")
    end

    def finish_failure(upload, state, code)
      return if upload.reload.state == "staged"
      bounded = code.match?(/\A[a-z][a-z0-9_]{0,47}\z/) ? code : "validation_rejected"
      upload.update!(state: state, result_code: bounded)
    end

    def current_owner!(id, version)
      owner = User.lock.find_by(id: id)
      Identity::Capabilities.require!(owner, :manage_themes)
      raise Manager::Protected, "upload_owner_changed" unless owner.auth_version == version
      owner
    end

    def site_uploads(site) = ThemeUpload.where(site: site)
  end
end
