module Admin
  class ThemesController < BaseController
    before_action -> { authorize!(:manage_themes) }
    rescue_from Themes::Manager::Conflict, Themes::Manager::Protected, ActiveRecord::StaleObjectError do
      render_core_error("Theme state changed or this package is protected. Reload before trying again.", status: :conflict)
    end
    rescue_from Railpress::ThemePackage::Invalid, ArgumentError, ActiveRecord::RecordNotFound do
      render_core_error("Theme validation failed. The current theme was preserved.", status: :unprocessable_entity)
    end
    def customize
      index
    end
    def index
      @state = ThemeState.find_by(site: Site.find_by!(singleton_key: 1))
      @packages = ThemeInstallation.where(status: "validated").order(:theme_key, :version, :digest).limit(100)
      @theme_media = MediaLibrary::Policy.scope(current_user).ready.where(content_type: "image/png").where("width <= 1024 AND height <= 1024").where.not(alt_text: "").order(:title).limit(100).map { |asset| [ asset.title, asset.id ] }
    end
    def overlay
      package = ThemeInstallation.find(params[:id])
      attributes = params.require(:overlay).to_unsafe_h
      Themes::Manager.overlay!(actor: current_user, installation: package, attributes: attributes)
      redirect_to admin_themes_path, status: :see_other
    end
    def preview
      package = ThemeInstallation.find(params[:id])
      session[:theme_preview] = Themes::Manager.preview!(actor: current_user, installation: package, overlay: package.theme_overlays.find(params[:overlay_id]), authentication_token: session[:authentication_token])
      redirect_to root_path, status: :see_other
    end
    def stop_preview
      if session[:theme_preview]
        token = session[:theme_preview]["token"] || session[:theme_preview][:token]
        ThemePreview.where(actor: current_user, token_digest: Digest::SHA256.hexdigest(token.to_s)).delete_all
      end
      session.delete(:theme_preview)
      redirect_to admin_themes_path, status: :see_other
    end
    def activate
      package = ThemeInstallation.find(params[:id])
      Themes::Manager.activate!(actor: current_user, installation: package, overlay: package.theme_overlays.find(params[:overlay_id]), version: params[:version])
      redirect_to admin_themes_path, status: :see_other
    end
    def revert
      Themes::Manager.revert!(actor: current_user, version: params[:version])
      redirect_to admin_themes_path, status: :see_other
    end
    def destroy
      Themes::Manager.remove!(actor: current_user, installation: ThemeInstallation.find(params[:id]))
      redirect_to admin_themes_path, status: :see_other
    end
  end
end
