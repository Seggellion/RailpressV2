# frozen_string_literal: true

module Admin
  class ModuleCatalogController < BaseController
    skip_before_action :require_authentication, only: :review
    skip_before_action :require_admin_access, only: :review
    before_action :load_site
    before_action :catalog_owner, except: :review

    rescue_from Railpress::Extensions::Invalid do
      render_core_error("The module request could not be verified. Start a fresh review for this site.", status: :conflict)
    end
    rescue_from ActiveRecord::RecordNotFound do
      render_core_error("The module request was not found on this site.", status: :not_found)
    end

    def review
      @hints = Extensions::CatalogHandoff.identifiers(params[:module], params[:catalog])
      unless current_user
        session[:module_catalog_intent] = Extensions::CatalogHandoff.sign_in_intent(site: @site, hints: @hints) if request.get?
        return redirect_to login_path, status: :see_other
      end
      catalog_owner
      @installation = Extensions::CatalogHandoff.site_installation(@site, @hints.fetch("module"))
      @request = ExtensionInstallRequest.where(site: @site, module_id: @hints.fetch("module")).order(id: :desc).first
      @registry = Railpress::Extensions.registry
      begin
        catalog, @offer, @entry = Extensions::CatalogHandoff.review(@hints, registry: @registry)
        unless @installation&.package_state == "installed" || Extensions::Requests.pending?(@site)
          @confirmation = Extensions::CatalogHandoff.confirmation(site: @site, actor: current_user,
            token: session[:authentication_token], hints: @hints, catalog: catalog, row: @offer, registry: @registry)
        end
      rescue Railpress::Extensions::Invalid => error
        @hold = Extensions::CatalogHandoff::REVIEW_ERRORS.fetch(error.message, "Catalog verification failed. Ask the operator to check the staged catalog and its trust.")
      end
    end

    def create
      operation = Extensions::CatalogHandoff.submit!(actor: current_user, token: session[:authentication_token],
        confirmation: params[:confirmation], base_url: request.base_url)
      redirect_to admin_module_request_path(operation.request_key), status: :see_other
    end

    def show
      @operation = lookup
      @installation = Extensions::CatalogHandoff.site_installation(@site, @operation.module_id)
      @registry = Railpress::Extensions.registry
    end

    def cancel
      operation = Extensions::Requests.cancel!(actor: current_user, request_key: lookup.request_key)
      redirect_to admin_module_request_path(operation.request_key), status: :see_other
    end

    private

    def catalog_owner = authorize!(:manage_modules)

    def load_site
      @site = Site.find_by!(singleton_key: 1)
      Extensions::CatalogHandoff.origin!(@site, request.base_url)
    end

    def lookup
      ExtensionInstallRequest.find_by!(site: @site, request_key: params[:id])
    end
  end
end
