# frozen_string_literal: true

class PublishContentJob < ApplicationJob
  def perform(id, version)
    clock = Railpress::SecurityClock.for_application
    approved_at = clock.scheduling_instant
    return false unless approved_at
    Content.transaction do
      site = Site.find_by!(singleton_key: 1)
      site.lock!
      candidate = Content.find_by(id: id)
      return false unless candidate && candidate.status == "scheduled" && candidate.lock_version == version.to_i && candidate.scheduled_at <= approved_at
      actor = User.lock.find_by(id: candidate.scheduled_by_id)
      content = Content.lock.find(id)
      approved_at = clock.scheduling_instant
      return false unless approved_at && content.status == "scheduled" && content.lock_version == version.to_i && content.scheduled_at <= approved_at
      content.managed_change do
        if Identity::Capabilities.allowed?(actor, :publish_others)
          Editorial::Workflow.publish!(content, site, actor)
          event = "scheduled_publish"
        else
          Editorial::Workflow.withdraw!(content)
          event = "schedule_cancelled"
        end
        content.save!
        Editorial::Workflow.revision!(content, actor, event)
      end
      true
    end
  end
end
