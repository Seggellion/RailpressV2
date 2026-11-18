# frozen_string_literal: true

require "tmpdir"
require "digest"
module MediaLibrary
  class Upload
    class Rejected < StandardError
      attr_reader :diagnostic
      def initialize(message, diagnostic: nil)
        @diagnostic = diagnostic
        super(message)
      end
    end
    def self.call(actor:, io:, filename:, content_type:, attributes: {}, import_item: nil, import_thumbnail: nil)
      directory = nil
      attempt = nil
      accepted = false
      raise Rejected, "import_context_required" if import_thumbnail && !import_item
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor&.lock!
        Policy.upload!(actor)
        if import_item
          Portability::Authority.record_locked(import_item.import_batch) { Portability::Context.require_item!(import_item) }
          raise Rejected, "import_media_budget" unless import_item.kind == "media" && import_item.import_batch.import_items.where(kind: "media").count <= 64 && !import_item.target_id
        else
          allowed = AuthenticationThrottle.consume?(scope: "media-upload", identity: actor.id.to_s, limit: 10, window: 10.minutes)
          raise Rejected, "rate_limit" unless allowed
        end
        attempt = MediaUpload.create!(author: actor)
        import_item&.update!(details: import_item.details.merge("media_upload_id" => attempt.id))
      end
      directory = Dir.mktmpdir("upload-", Storage.work_root)
      input = File.join(directory, "input")
      digest = Digest::SHA256.new
      count = 0
      File.open(input, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode
        while (bytes = io.read(16_384)) && !bytes.empty?
          count += bytes.bytesize
          raise Rejected, "size" if count > Railpress::ImageInput::MAX_BYTES
          digest.update(bytes)
          file.write(bytes)
        end
      end
      info = Railpress::ImageInput.inspect!(File.binread(input))
      base = filename.to_s.tr("\\", "/").split("/").last.to_s.gsub(/[\x00-\x1f\x7f]/, "")[0, 150]
      extension = File.extname(base).downcase
      expected = info[:format] == "png" ? [ ".png" ] : [ ".jpg", ".jpeg" ]
      raise Rejected, "type_mismatch" unless content_type == info[:type] && expected.include?(extension)
      decoded = Processor.run!(input, directory)
      ImportVariants.preserve!(item: import_item, display: input, thumbnail: import_thumbnail, directory: directory, decoded: decoded) if import_item
      keys = 2.times.map { SecureRandom.hex(32) }
      attempt.update!(byte_size: count, source_sha256: digest.hexdigest, storage_keys: keys)
      asset = Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor.lock!
        Policy.upload!(actor)
        Portability::Authority.record_locked(import_item.import_batch) { Portability::Context.require_item!(import_item) } if import_item
        attempt.lock!
        raise Rejected, "expired" unless attempt.state == "processing"
        blobs = %w[display.png thumb.png].each_with_index.map do |name, index|
          File.open(File.join(directory, name), "rb") do |file|
            Storage.upload_blob!(key: keys[index], io: file, filename: name)
          end
        end
        values = attributes.to_h.slice(*MediaAsset::METADATA)
        values["title"] = values["title"].presence || base
        asset = MediaAsset.create!(values.merge(author: actor, public_id: SecureRandom.uuid,
          blob: blobs[0], thumbnail_blob: blobs[1], filename: base, content_type: "image/png",
          source_sha256: digest.hexdigest, sha256: Digest::SHA256.file(File.join(directory, "display.png")).hexdigest,
          thumbnail_sha256: Digest::SHA256.file(File.join(directory, "thumb.png")).hexdigest,
          source_bytes: count, byte_size: File.size(File.join(directory, "display.png")),
          width: decoded.fetch("width"), height: decoded.fetch("height"), source_width: info[:width], source_height: info[:height]))
        attempt.update!(state: "accepted", reason: nil)
        if import_item
          original = import_item.details.fetch("source_record")
          raise Rejected, "import_variant_not_lossless" unless asset.sha256 == original["display"]["sha256"] && asset.thumbnail_sha256 == original["thumbnail"]["sha256"]
          Portability::Identities.bind!(import_item.import_batch.site, "media", asset.id, original.fetch("ref"))
          import_item.update!(target_id: asset.id, created_record: true, state: "staged")
          import_item.update!(target_sha256: Portability::Fingerprint.current(import_item))
        end
        Activity::Recorder.record!(actor: actor, action: "media.upload", subject: asset, owner_id: actor.id)
        asset
      end
      accepted = true
      asset
    rescue Railpress::ImageInput::Invalid, Processor::Failed, Rejected, ActiveRecord::RecordInvalid => error
      attempt&.reload
      attempt&.update!(state: "rejected", reason: error.is_a?(ActiveRecord::RecordInvalid) ? "metadata" : error.message[0, 32], byte_size: count || 0) unless attempt&.state == "accepted"
      raise Rejected.new("Upload rejected: #{error.is_a?(ActiveRecord::RecordInvalid) ? 'metadata' : error.message[0, 32]}",
        diagnostic: error.respond_to?(:diagnostic) ? error.diagnostic : nil)
    ensure
      begin
        if attempt && !accepted
          current = MediaUpload.find_by(id: attempt.id)
          if current && current.state != "accepted"
            Array(current.storage_keys).each { |key| Storage.delete_key!(key) }
            current.update!(storage_keys: []) unless Storage.retained?
          end
        end
      rescue StandardError
        Rails.logger.warn("Media upload cleanup retained for retry")
      ensure
        Storage.remove_work!(directory) if directory && File.directory?(directory)
      end
    end
  end
end
