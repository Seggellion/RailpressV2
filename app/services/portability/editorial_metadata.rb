module Portability
  module EditorialMetadata
    module_function
    def attach!(actor:, content:, expected_version:, metadata:)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor = User.lock.find(actor.id)
        Identity::Capabilities.require!(actor, :manage_identity)
        content.lock!; Authority.version!(content, expected_version)
        Format.metadata!(metadata)
        content.managed_change { content.update!(portable_metadata: metadata) }
        Editorial::Workflow.revision!(content, actor, "save")
        content
      end
    end
  end
end
