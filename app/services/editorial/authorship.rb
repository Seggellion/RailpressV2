module Editorial
  module Authorship
    module_function
    def transfer!(actor:, content:, author_id:, version:)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!; actor.lock!; content.lock!
        Identity::Capabilities.require!(actor, :manage_users)
        raise Workflow::Conflict, "Authorship changed. Reload and compare before transferring." unless version.to_s == content.lock_version.to_s
        target = User.lock.find_by(id: author_id)
        raise Workflow::Invalid, "Choose an existing account" unless target
        previous = content.author_id
        content.managed_change do
          Workflow.withdraw!(content) if content.status == "scheduled"
          content.author = target
          content.updated_at_will_change!
          content.save!
          Workflow.revision!(content, actor, "reassign", details: { previous_author_id: previous, new_author_id: target.id })
        end
        content
      end
    end
  end
end
