# frozen_string_literal: true

module Editorial
  class Workflow
    class Conflict < StandardError; end
    class Invalid < StandardError; end
    FIELDS = %w[title slug body excerpt visibility template_key meta_title meta_description home_page].freeze
    EVENTS = %w[save submit publish schedule unpublish trash restore restore_revision].freeze
    def self.create!(actor:, kind:, attributes:)
      raise Invalid, "Choose Page or Post" unless %w[Page Post].include?(kind)
      Content.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor.lock!
        Identity::Capabilities.require!(actor, :edit_own)
        content = kind.constantize.new(attributes.to_h.slice(*FIELDS).merge(author: actor, status: "draft"))
        MediaLibrary::References.working!(actor: actor, content: content, attributes: attributes)
        content.save!
        sync_terms!(content, attributes["term_ids"], "draft")
        MediaLibrary::References.sync!(content, "draft", MediaLibrary::References.ids(content.snapshot))
        revision!(content, actor, "create")
        content
      end
    end

    def self.update!(actor:, content:, expected_version:, attributes: {}, event: "save", revision_id: nil)
      raise Invalid, "Unknown editorial action" unless EVENTS.include?(event)
      result = Content.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        actor.lock!
        content.lock!
        raise Identity::Capabilities::Denied unless Identity::Capabilities.can_edit_content?(actor, author_id: content.author_id)
        raise Conflict, "Another change was saved. Compare the current version and reapply your edits." unless expected_version.to_s == content.lock_version.to_s
        raise Invalid, "Restore this item before editing" if content.status == "trashed" && event != "restore"
        if %w[publish schedule unpublish trash restore restore_revision].include?(event)
          Identity::Capabilities.require!(actor, :publish_others) unless event == "trash" && content.status == "draft" && actor.id == content.author_id
        end
        content.managed_change do
          if event == "restore_revision"
            revision = content.content_revisions.find(revision_id)
            content.assign_attributes(revision.snapshot.slice(*FIELDS))
            sync_terms!(content, revision.snapshot["term_ids"], "draft")
            content.blocks = ContentBlocks::Schema.normalize(revision.snapshot["blocks"])
            content.featured_media_id = revision.snapshot["featured_media_id"]
            content.media_details = revision.snapshot["media_details"] || {}
            content.portable_metadata = revision.snapshot["portable_metadata"] || {}
            MediaLibrary::References.sync!(content, "draft", MediaLibrary::References.ids(revision.snapshot))
            withdraw!(content)
          else
            content.assign_attributes(attributes.to_h.slice(*FIELDS))
            sync_terms!(content, attributes["term_ids"], "draft") if attributes.key?("term_ids")
          end
          MediaLibrary::References.working!(actor: actor, content: content, attributes: attributes) unless event == "restore_revision"
          withdraw!(content) if content.status == "scheduled" && %w[save submit].include?(event)
          case event
          when "save"
            content.status = "draft" if content.status == "pending"
            content.pending_review = false
          when "submit"
            content.status = "pending" unless content.status == "published"
            content.pending_review = true
          when "publish"
            publish!(content, site, actor)
          when "schedule"
            time = LocalTime.parse(attributes["schedule_local"], site.timezone)
            raise Invalid, "Schedule must be in the future" unless time > Time.current
            withdraw!(content)
            content.status = "scheduled"
            content.scheduled_at = time
            content.scheduled_by_id = actor.id
          when "unpublish", "restore"
            withdraw!(content)
          when "trash"
            withdraw!(content)
            content.status = "trashed"
          end
          content.updated_at_will_change!
          content.save!
          revision!(content, actor, event)
        end
        content
      end
      if event == "schedule"
        begin
          PublishContentJob.set(wait_until: result.scheduled_at).perform_later(result.id, result.lock_version)
        rescue StandardError
          Rails.logger.warn("Scheduled content #{result.id} retained for the recurring due sweep")
        end
      end
      result
    end

    def self.publish!(content, site, actor)
      content.valid? || raise(ActiveRecord::RecordInvalid, content)
      content.status = "published"
      content.published_visibility = content.visibility
      content.published_at = Time.current
      content.first_published_at ||= content.published_at
      content.scheduled_at = nil
      content.scheduled_by_id = nil
      content.pending_review = false
      MediaLibrary::References.sync!(content, "live", MediaLibrary::References.ids(content.snapshot))
      content.published_snapshot = content.snapshot
      content.public_updated_at = Time.current
      content.public_search_text = [ content.published_snapshot["title"], content.published_snapshot["excerpt"] ].join(" ")
      sync_terms!(content, content.snapshot["term_ids"], "live")
      if content.is_a?(Page)
        site.update!(homepage_content_id: content.home_page ? content.id : nil) if content.home_page || site.homepage_content_id == content.id
      end
    end

    def self.withdraw!(content)
      content.status = "draft"
      content.published_snapshot = nil
      content.public_search_text = nil
      content.published_visibility = nil
      content.published_at = nil
      content.scheduled_at = nil
      content.scheduled_by_id = nil
      content.pending_review = false
      content.content_terms.where(stage: "live").delete_all
      content.media_references.where(stage: "live").delete_all
    end

    def self.sync_terms!(content, ids, stage)
      ids = Array(ids).reject(&:blank?).map { |id| Integer(id.to_s, 10) }.uniq
      raise Invalid, "Use at most 30 existing terms" if ids.length > 30 || Term.where(id: ids).lock.pluck(:id).length != ids.length
      content.content_terms.where(stage: stage).delete_all
      ids.each { |id| content.content_terms.create!(term_id: id, stage: stage) }
    rescue ArgumentError
      raise Invalid, "Choose existing terms"
    end

    def self.revision!(content, actor, event, details: {})
      number = (content.content_revisions.order(number: :desc).lock.first&.number || 0) + 1
      revision = content.content_revisions.create!(actor: actor, number: number, event: event,
        snapshot: content.snapshot.merge("status" => content.status, "scheduled_at" => content.scheduled_at&.iso8601, "published_at" => content.published_at&.iso8601))
      MediaLibrary::References.sync!(revision, "revision", MediaLibrary::References.ids(revision.snapshot))
      Activity::Recorder.record!(actor: actor, action: "content.#{event}", subject: content, owner_id: content.author_id, details: { content_kind: content.type, state: content.status, revision: number }.merge(details))
      revision
    end
  end
end
