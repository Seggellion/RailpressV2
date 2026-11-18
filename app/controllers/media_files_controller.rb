class MediaFilesController < ApplicationController
  skip_before_action :require_https, only: :show
  before_action :require_authentication, except: :show
  def show
    content = Content.publicly_visible.find(params[:content_id])
    asset = MediaAsset.ready.find_by!(public_id: params[:public_id])
    raise ActiveRecord::RecordNotFound unless MediaReference.exists?(content_id: content.id, media_asset_id: asset.id, stage: "live")
    deliver(asset)
  end
  def private_file
    asset = MediaAsset.ready.find(params[:id])
    MediaLibrary::Policy.read!(current_user, asset)
    deliver(asset)
  end
  def preview
    credential = session[:editorial_preview] || {}
    record = Editorial::Previews.resolve!(actor: current_user, id: params[:preview_id], token: credential["token"])
    asset = MediaAsset.ready.find_by!(public_id: params[:public_id])
    raise ActiveRecord::RecordNotFound unless MediaReference.exists?(content_preview_id: record.id, media_asset_id: asset.id, stage: "preview")
    deliver(asset)
  end
  private
  def deliver(asset)
    bytes = MediaLibrary::Delivery.read(asset, params[:variant].presence || "display")
    raise ActiveRecord::RecordNotFound unless bytes
    response.set_header("Cache-Control", "no-store")
    response.set_header("X-Content-Type-Options", "nosniff")
    response.set_header("Content-Security-Policy", "default-src 'none'; sandbox")
    send_data bytes, type: "image/png", disposition: params[:download] == "1" ? "attachment" : "inline", filename: "media-#{asset.public_id}.png"
  end
end
