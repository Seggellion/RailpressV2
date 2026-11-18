class OfficialNewsSweepJob < ApplicationJob
  queue_as :default
  def perform
    OfficialNewsState.where(enabled: true).limit(1).pluck(:id, :generation).each do |id, generation|
      OfficialNews::Refresh.new.call(id, generation)
    end
  end
end
