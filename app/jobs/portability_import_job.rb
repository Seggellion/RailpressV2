class PortabilityImportJob < ApplicationJob
  queue_as :default
  def perform(id)
    Portability::Worker.perform!(ImportBatch.find(id))
  rescue Portability::Authority::Expired, Portability::Format::Invalid, Portability::Imports::Conflict, ActiveRecord::RecordInvalid, MediaLibrary::Upload::Rejected, IOError, SystemCallError
    # The durable batch is stopped with a real error. No automatic reapproval,
    # overwrite, timeout increase or fresh security deadline.
    nil
  end
end
