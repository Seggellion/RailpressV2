class StorageConfigurationJob < ApplicationJob
  queue_as :default
  def perform
    MediaLibrary::Configuration.record_worker!
  end
end
