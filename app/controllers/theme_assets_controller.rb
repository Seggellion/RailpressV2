class ThemeAssetsController < ApplicationController
  skip_before_action :require_https
  rescue_from Railpress::ThemePackage::Invalid, ActiveRecord::RecordNotFound, ArgumentError do
    head :not_found
  end
  def show
    return head :upgrade_required if Rails.env.production? && !secure_transport?
    package = ThemeInstallation.find_by!(theme_key: params[:theme_key], version: params[:version], digest: params[:digest])
    preview = Themes::Selection.preview(current_user, session[:authentication_token], session[:theme_preview])
    raise ActiveRecord::RecordNotFound unless package.ever_active_at || preview&.installation&.id == package.id
    bundle = Themes::Storage.load(package, allow_removed: true)
    asset = bundle.manifest["assets"].values.find { |entry| entry["file"] == "assets/#{params[:file]}" }
    raise ActiveRecord::RecordNotFound unless asset
    response.set_header("Cache-Control", package.ever_active_at ? "public, max-age=31536000, immutable" : "no-store")
    response.set_header("X-Content-Type-Options", "nosniff")
    response.set_header("Content-Security-Policy", "default-src 'none'; sandbox")
    send_data bundle.files.fetch(asset["file"]), type: asset["content_type"], disposition: "inline"
  end
  def media
    return head :upgrade_required if Rails.env.production? && !secure_transport?
    pair = Themes::Selection.call(site: Site.find_by!(singleton_key: 1), actor: current_user, authentication_token: session[:authentication_token], credential: session[:theme_preview])
    raise ActiveRecord::RecordNotFound unless pair && pair.overlay.id.to_s == params[:overlay_id].to_s && %w[logo favicon].include?(params[:kind])
    detail = pair.overlay.media_details.fetch(params[:kind])
    asset = MediaAsset.ready.find(detail.fetch("asset_id"))
    raise ActiveRecord::RecordNotFound unless MediaReference.exists?(theme_overlay: pair.overlay, media_asset: asset, stage: "theme")
    bytes = MediaLibrary::Delivery.read(asset, "display")
    raise ActiveRecord::RecordNotFound unless bytes
    response.set_header("Cache-Control", "no-store")
    response.set_header("X-Content-Type-Options", "nosniff")
    response.set_header("Content-Security-Policy", "default-src 'none'; sandbox")
    send_data bytes, type: "image/png", disposition: "inline"
  rescue KeyError
    head :not_found
  end
end
