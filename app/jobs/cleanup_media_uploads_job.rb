class CleanupMediaUploadsJob < ApplicationJob
  def perform
    MediaUpload.where(state: %w[processing rejected]).where("updated_at < ?", 1.hour.ago).find_each do |upload|
      keys = Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        upload.lock!
        next [] if upload.state == "accepted" || upload.updated_at >= 1.hour.ago
        upload.update!(state: "rejected", reason: upload.reason.presence || "interrupted")
        Array(upload.storage_keys)
      end
      begin
        keys.each { |key| MediaLibrary::Storage.delete_key!(key) }
        upload.update!(storage_keys: []) unless keys.empty? || MediaLibrary::Storage.retained?
      rescue StandardError
        Rails.logger.warn("Interrupted media cleanup retained for retry")
      end
    end
    Site.transaction do
      Site.find_by!(singleton_key: 1).lock!
      expired = ContentPreview.where("expires_at <= ?", Time.current).lock.pluck(:id)
      MediaReference.where(content_preview_id: expired).delete_all
      ContentPreview.where(id: expired).delete_all
    end
    MediaUpload.where(state: "rejected").where("updated_at < ?", 7.days.ago).find_each do |upload|
      upload.destroy! if Array(upload.storage_keys).empty?
    end
  end
end
