module Editorial
  # A narrow extension of the editorial authority for approved private imports.
  # No controller exposes these fields or accepts an import context.
  module PortableContent
    module_function
    def create!(actor:, item:, snapshot:, author_id:)
      Portability::Context.require_item!(item)
      content = Workflow.create!(actor: actor, kind: snapshot.fetch("type"), attributes: snapshot)
      content.managed_change do
        content.update!(author_id: author_id, portable_metadata: snapshot.fetch("portable_metadata"), media_details: snapshot.fetch("media_details"))
      end
      # The normal create audit remains. Imported source numbers are separately
      # mapped and never overwrite a destination revision number.
      content
    end
    def revision!(actor:, item:, content:, snapshot:, history:, source_number:, source_event:, source_created_at:)
      Portability::Context.require_item!(item)
      number = content.content_revisions.maximum(:number).to_i + 1
      revision = content.content_revisions.create!(actor: actor, number: number, event: "import_history",
        snapshot: snapshot.merge("status" => history.fetch("state"), "published_at" => history["published_at"], "scheduled_at" => history["scheduled_at"]))
      MediaLibrary::References.sync!(revision, "revision", MediaLibrary::References.ids(snapshot))
      revision
    end
    def apply_working!(actor:, content:, attributes:, author_id:)
      Workflow.update!(actor: actor, content: content, expected_version: content.lock_version, attributes: attributes, event: "save")
      content.managed_change { content.update!(author_id: author_id, portable_metadata: attributes.fetch("portable_metadata"), media_details: attributes.fetch("media_details")) }
      content
    end
  end
end
