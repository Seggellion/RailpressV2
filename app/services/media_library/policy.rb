module MediaLibrary
  module Policy
    module_function
    def upload!(actor)
      raise Identity::Capabilities::Denied unless actor && (Identity::Capabilities.allowed?(actor, :manage_media) || Identity::Capabilities.allowed?(actor, :upload_own))
    end
    def read!(actor, asset)
      upload!(actor)
      raise Identity::Capabilities::Denied unless asset.author_id == actor.id || Identity::Capabilities.allowed?(actor, :manage_media)
    end
    def scope(actor)
      upload!(actor)
      Identity::Capabilities.allowed?(actor, :manage_media) ? MediaAsset.all : MediaAsset.where(author_id: actor.id)
    end
  end
end
