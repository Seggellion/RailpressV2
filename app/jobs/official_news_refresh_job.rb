class OfficialNewsRefreshJob < ApplicationJob
  queue_as :default
  def perform(id, generation)
    return unless id.is_a?(Integer) && generation.is_a?(Integer)
    OfficialNews::Refresh.new.call(id, generation)
  end
end
