class ReleaseCheckJob < ApplicationJob
  queue_as :default
  def perform
    Releases::Catalog.refresh! if Releases::Catalog.settings["enabled"]
  end
end
