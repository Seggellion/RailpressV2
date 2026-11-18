class PortabilityExportJob < ApplicationJob
  queue_as :default
  def perform(id)
    Portability::Exports.perform!(PortabilityExport.find(id))
  rescue Portability::Authority::Expired
    nil
  rescue Portability::Format::Invalid, ActiveRecord::RecordInvalid, IOError, SystemCallError => error
    record = PortabilityExport.find_by(id: id)
    record&.with_lock { record.update!(state: "failed", failure: error.class.name, report: record.report.merge("error" => error.is_a?(Portability::Format::Invalid) ? error.message : "Export could not complete. Inspect private storage and retry.")) }
  end
end
