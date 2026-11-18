module MediaLibrary
  module Manage
    class InUse < StandardError; end
    class Conflict < StandardError; end
    module_function
    def update!(actor:, asset:, attributes:, version:)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor.lock!
        asset.lock!
        Policy.read!(actor, asset)
        raise Conflict, "Media changed; reload before saving" unless version.to_s == asset.lock_version.to_s && asset.state == "ready"
        asset.managed_change { asset.update!(attributes.to_h.slice(*MediaAsset::METADATA)) }
        Activity::Recorder.record!(actor: actor, action: "media.update", subject: asset, owner_id: asset.author_id)
      end
      asset
    end
    def purge!(actor:, asset:)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor.lock!
        asset.lock!
        Policy.read!(actor, asset)
        raise InUse, "Retained content, revisions or previews reference this media" if asset.media_references.lock.first
        asset.managed_change { asset.update!(state: "purging") } unless asset.state == "purged"
        Activity::Recorder.record!(actor: actor, action: "media.purge", subject: asset, owner_id: asset.author_id, details: { state: asset.state })
      end
      return asset if asset.state == "purged"
      blobs = [ asset.blob, asset.thumbnail_blob ].compact
      retained = blobs.any? { |blob| Storage.retained?(blob.service) }
      blobs.each { |blob| Storage.delete_key!(blob.key) } unless retained
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor.lock!
        asset.lock!
        Policy.read!(actor, asset)
        raise InUse if asset.media_references.lock.first
        values = { state: "purged", blob: nil, thumbnail_blob: nil }
        values[:retained_objects] = blobs.map { |blob| blob.metadata.fetch("railpress_gcs") } if retained
        asset.managed_change { asset.update!(values) }
        blobs.each(&:destroy!)
        Activity::Recorder.record!(actor: actor, action: "media.purge", subject: asset, owner_id: asset.author_id, details: { state: "purged" })
      end
      asset
    end
  end
end
