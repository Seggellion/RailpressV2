class ThemeAssetsController < ApplicationController
  skip_before_action :require_https
  rescue_from Railpress::ThemePackage::Invalid, ActiveRecord::RecordNotFound, ArgumentError do
    head :not_found
  end
  def show
    return head :upgrade_required if Rails.env.production? && !secure_transport?
    package = selected_package
    raise ActiveRecord::RecordNotFound unless package.ever_active_at
    send_asset(package, preview: false)
  end
  def preview
    response.set_header("Cache-Control", "no-store")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    return head :upgrade_required unless secure_transport?
    pair = Themes::Selection.preview(current_user, session[:authentication_token], session[:theme_preview])
    package = selected_package
    raise ActiveRecord::RecordNotFound unless pair&.installation&.id == package.id
    send_asset(package, preview: true)
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

  private

  def selected_package
    site = Site.find_by!(singleton_key: 1)
    ThemeInstallation.find_by!(site: site, theme_key: params[:theme_key], version: params[:version], digest: params[:digest])
  end

  def send_asset(package, preview:)
    bundle = Themes::Storage.load(package, allow_removed: !preview)
    asset = bundle.manifest["assets"].values.find { |entry| entry["file"] == "assets/#{params[:file]}" }
    raise ActiveRecord::RecordNotFound unless asset
    response.set_header("Cache-Control", preview ? "no-store" : "public, max-age=31536000, immutable")
    response.set_header("X-Content-Type-Options", "nosniff")
    response.set_header("Content-Security-Policy", "default-src 'none'; sandbox")
    send_data bundle.files.fetch(asset["file"]), type: asset["content_type"], disposition: "inline"
  end
end
