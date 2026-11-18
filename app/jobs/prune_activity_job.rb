class PruneActivityJob < ApplicationJob
  def perform
    Site.find_each do |site|
      site.with_lock { Activity::Recorder.prune!(site) }
    end
    AuthenticationThrottle.where("updated_at < ?", 1.day.ago).order(:id).limit(500).pluck(:id).then do |ids|
      AuthenticationThrottle.where(id: ids).delete_all if ids.any?
    end
  end
end
