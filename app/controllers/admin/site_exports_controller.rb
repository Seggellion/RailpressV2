module Admin
  class SiteExportsController < BaseController
    before_action -> { authorize!(:manage_identity) }
    rescue_from Portability::Format::Invalid, Portability::Authority::Expired do |error|
      render_core_error(error.message, status: :unprocessable_entity)
    end
    def create
      ids = Array(params[:content_ids]).map { |id| Integer(id, 10) }
      raise Portability::Format::Invalid, "Author labels must be a collection." if params[:author_labels] && !params[:author_labels].is_a?(ActionController::Parameters)
      raise Portability::Format::Invalid, "Media rights must be a collection." if params[:media_rights] && !params[:media_rights].is_a?(ActionController::Parameters)
      labels = (params[:author_labels]&.to_unsafe_h || {}).reject { |_id, label| label.blank? }
      rights = (params[:media_rights]&.to_unsafe_h || {}).filter_map do |id, values|
        raise Portability::Format::Invalid, "Media rights must be structured." unless values.is_a?(Hash)
        next unless values["confirmed"] == "1"
        [ id, { "status"=>"cleared", "license"=>values["license"], "attribution"=>values["attribution"] } ]
      end.to_h
      scope = { "mode"=>params[:mode], "content_ids"=>ids, "history"=>params[:history] == "1", "menus"=>params[:menus] == "1", "appearance"=>params[:appearance] == "1", "author_labels"=>labels, "media_rights"=>rights }
      record = Portability::Exports.request!(actor: current_user, session_id: Current.user_session.id, scope: scope)
      PortabilityExportJob.perform_later(record.id)
      redirect_to admin_site_export_path(record.public_id), status: :see_other
    rescue Portability::Format::Invalid, Portability::Authority::Expired, ArgumentError, TypeError => error
      redirect_to admin_imports_path, notice: "Export was not requested: #{error.message}", status: :see_other
    end
    def show
      @export = PortabilityExport.where(site: Site.find_by!(singleton_key: 1)).find_by!(public_id: params[:id])
    end
    def download
      record = PortabilityExport.where(site: Site.find_by!(singleton_key: 1)).find_by!(public_id: params[:id])
      Portability::Authority.locked(actor: current_user, session_id: Current.user_session.id) do
        record.lock!
        raise Portability::Format::Invalid, "Export is not ready." unless record.state == "ready"
        Activity::Recorder.record!(actor: current_user, action: "portability.export_downloaded", subject: record)
        send_data Portability::Store.read(record), type: "application/octet-stream", filename: "railpress-#{record.public_id}.railpress", disposition: "attachment"
      end
    end
  end
end
