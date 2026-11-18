module Admin
  class ExportsController < BaseController
    before_action -> { authorize!(:manage_identity) }
    rescue_from Portability::Export::TooLarge, Portability::Validate::Invalid do
      render_core_error("Selection exceeds supported manifest limits. Complete archives and import are not available yet.", status: :unprocessable_entity)
    end
    def new
    end
    def create
      manifest = Portability::Export.call(actor: current_user, include_private: params[:include_private] == "1")
      json = JSON.pretty_generate(manifest)
      Portability::Validate.call(json)
      send_data json, type: "application/json", filename: "railpress-content-v1.json", disposition: "attachment"
    end
  end
end
