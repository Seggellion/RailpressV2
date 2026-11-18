class AssessReadinessJob < ApplicationJob
  queue_as :default
  def perform(id)
    MediaLibrary::Configuration.record_worker!
    Readiness::Assessment.execute!(id)
  end
end
