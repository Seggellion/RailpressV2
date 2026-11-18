class PublishDueContentJob < ApplicationJob
  def perform
    approved_at = Railpress::SecurityClock.for_application.scheduling_instant
    return false unless approved_at
    Content.where(status: "scheduled").where("scheduled_at <= ?", approved_at).find_each do |content|
      PublishContentJob.perform_later(content.id, content.lock_version)
    end
  end
end
