module Admin
  class MediaAssetsController < BaseController
    before_action -> { MediaLibrary::Policy.upload!(current_user) }
    before_action :load_asset, only: [ :show, :update, :destroy ]
    rescue_from MediaLibrary::Upload::Rejected, ActiveRecord::RecordInvalid, MediaLibrary::Manage::Conflict do |error|
      @error = error.is_a?(MediaLibrary::Upload::Rejected) ? error.message : "Media metadata is invalid or changed; reload and review."
      @asset ? render(:show, status: :unprocessable_entity) : render(:new, status: :unprocessable_entity)
    end
    rescue_from MediaLibrary::Manage::InUse do
      @error = "Purge refused: retained content, revisions or previews still reference this image."
      render :show, status: :conflict
    end
    rescue_from MediaLibrary::Storage::Unsafe do
      render_core_error("Private media storage is not qualified. Contact the host operator.", status: :service_unavailable)
    end
    rescue_from Railpress::Gcs::Failure do
      render_core_error("Media storage is unavailable. Try again later or contact the site operator. Your existing images remain unchanged.", status: :service_unavailable)
    end
    def index
      @query = params[:q].to_s[0, 100]
      @assets = MediaLibrary::Policy.scope(current_user).where.not(state: "purged")
      @assets = @assets.where("LOWER(title) LIKE ?", "%#{MediaAsset.sanitize_sql_like(@query.downcase)}%") if @query.present?
      @assets = @assets.order(id: :desc).limit(50)
      @attempts = MediaUpload.where(author_id: current_user.id).order(id: :desc).limit(10)
    end
    def new
    end
    def create
      file = params[:file]
      raise MediaLibrary::Upload::Rejected, "Choose a PNG or JPEG file" unless file.respond_to?(:tempfile)
      asset = MediaLibrary::Upload.call(actor: current_user, io: file.tempfile, filename: file.original_filename,
        content_type: file.content_type, attributes: metadata)
      redirect_to admin_media_asset_path(asset), notice: "Image validated and stored privately.", status: :see_other
    end
    def show
    end
    def update
      MediaLibrary::Manage.update!(actor: current_user, asset: @asset, attributes: metadata, version: params[:version])
      redirect_to admin_media_asset_path(@asset), notice: "Media metadata saved. Republish content to update its saved accessibility metadata.", status: :see_other
    end
    def destroy
      MediaLibrary::Manage.purge!(actor: current_user, asset: @asset)
      notice = @asset.retained_objects.present? ? "Image removed from the library. Stored files are retained for backups." : "Unused canonical image and thumbnail purged."
      redirect_to admin_media_assets_path, notice: notice, status: :see_other
    end
    private
    def metadata
      params.fetch(:media_asset, ActionController::Parameters.new).permit(*MediaAsset::METADATA).to_h
    end
    def load_asset
      @asset = MediaAsset.find(params[:id])
      MediaLibrary::Policy.read!(current_user, @asset)
    end
  end
end
