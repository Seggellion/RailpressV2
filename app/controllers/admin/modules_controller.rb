# frozen_string_literal: true

module Admin
  class ModulesController < BaseController
    before_action -> { authorize!(:manage_modules) }

    rescue_from Railpress::Extensions::Invalid, ActionController::ParameterMissing do |error|
      message = if error.message == "extension_route_collision"
        "A page or redirect uses this module's public path. Move it before enabling the module."
      else
        "The module request could not be verified. Reload Modules and review the exact selection."
      end
      render_core_error(message, status: :conflict)
    end
    rescue_from ActiveRecord::RecordNotFound do
      render_core_error("The module was not found on this site.", status: :not_found)
    end

    def index
      @registry = Railpress::Extensions.registry
      @site = Site.find_by!(singleton_key: 1)
      @installations = ExtensionInstallation.where(site: @site).order(:module_id).index_by(&:module_id)
      @requests = ExtensionInstallRequest.where(site: @site).order(id: :desc).limit(30)
    end

    def create
      input = params.require(:selection)
      raise Railpress::Extensions::Invalid, "extension_selection" unless input.is_a?(ActionController::Parameters)
      selection = input.permit(:request_key, :operation, :module_id, :version, :package_sha256,
        :manifest_sha256, :plan_sha256, :engine_generation, :engine_fingerprint, :activation_generation).to_h
      %w[engine_generation activation_generation].each { |key| selection[key] = generation!(selection[key]) }
      Extensions::Requests.submit!(actor: current_user, selection: selection)
      redirect_to admin_modules_path, status: :see_other, notice: "Module request recorded. The operator must verify and fulfill it."
    end

    def enable
      change!(true)
    end

    def disable
      change!(false)
    end

    private

    def change!(enabled)
      Extensions::Activation.change!(actor: current_user, module_id: params[:id], generation: generation!(params[:generation]), enabled: enabled)
      operation = ExtensionInstallRequest.find_by(site: Site.find_by!(singleton_key: 1), request_key: params[:installation_request],
        module_id: params[:id], state: "installed") if enabled && params[:installation_request].is_a?(String)
      target = operation ? admin_module_request_path(operation.request_key) : admin_modules_path
      redirect_to target, status: :see_other, notice: enabled ? "Module enabled." : "Module disabled."
    end

    def generation!(value)
      unless value.is_a?(String) && value.match?(/\A(?:0|[1-9][0-9]{0,15})\z/)
        raise Railpress::Extensions::Invalid, "extension_generation"
      end
      Integer(value, 10)
    end
  end
end
