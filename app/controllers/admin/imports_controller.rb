module Admin
  class ImportsController < BaseController
    before_action -> { authorize!(:manage_identity) }
    before_action :load_batch, except: %i[index create]
    rescue_from Portability::Format::Invalid, Portability::Imports::Conflict, Portability::Authority::Expired, Editorial::Workflow::Conflict, Themes::Manager::Protected, ActiveRecord::RecordInvalid do |error|
      @error = error.message
      if @batch
        load_review
        render :show, status: :unprocessable_entity
      else
        load_index
        render :index, status: :unprocessable_entity
      end
    end
    rescue_from IOError, SystemCallError do
      @error = "Private archive storage is unavailable. No content was staged by this upload. Check its receipt in import history before retrying."
      load_index
      render :index, status: :service_unavailable
    end
    def index = load_index
    def create
      upload = params[:archive]
      raise Portability::Format::Invalid, "Choose a .railpress archive." unless upload.respond_to?(:read)
      batch = Portability::Imports.submit!(actor: current_user, session_id: Current.user_session.id, io: upload, idempotency_key: params[:idempotency_key])
      PortabilityImportJob.perform_later(batch.id) if batch.state == "queued"
      redirect_to admin_import_path(batch.public_id), notice: "Archive received. The native worker will validate it before any content is staged.", status: :see_other
    end
    def show = load_review
    def status
      render json: { state: @batch.state, progress: @batch.progress, total: @batch.total, failure: @batch.failure }
    end
    def inspect_archive
      Portability::Authority.record_locked(@batch) do
        Portability::Authority.version!(@batch, params[:version])
        raise Portability::Imports::Conflict, "Cannot inspect after staging." if @batch.import_items.exists?
        @batch.update!(state: "queued")
      end
      enqueue("A fresh dry run was requested.")
    end
    def approve
      decisions = params.require(:decisions).to_unsafe_h
      %w[authors unassigned].each { |key| decisions[key] = (decisions[key] || {}).transform_values { |v| strict_id(v) } }
      %w[content terms media].each do |key|
        decisions[key] ||= {}
        decisions[key].each_value do |choice|
          choice["target_id"] = strict_id(choice["target_id"]) if choice.key?("target_id") && choice["target_id"].present?
          choice.delete("target_id") if choice["target_id"].blank?
          choice["rights_confirmed"] = choice["rights_confirmed"] == "1" if key == "media"
        end
      end
      Portability::Imports.approve!(batch: @batch, actor: current_user, session_id: Current.user_session.id, expected_version: params[:version], decisions: decisions)
      enqueue("Private staging approved. Progress reports committed records only.")
    end
    def activate
      Portability::Activation.approve!(batch: @batch, actor: current_user, session_id: Current.user_session.id, expected_version: params[:version], content_refs: Array(params[:content_refs]), menus: params[:menus] == "1", settings: params[:settings] == "1", appearance: params[:appearance] == "1")
      enqueue("Separate activation approved for the selected public content and settings.")
    end
    def retry
      Portability::Imports.renew_approval!(batch: @batch, actor: current_user, session_id: Current.user_session.id, expected_version: params[:version])
      enqueue("Approval renewed explicitly. The worker will reconcile committed items before continuing.")
    end
    def reverse_batch
      Portability::Reversal.approve!(batch: @batch, actor: current_user, session_id: Current.user_session.id, expected_version: params[:version])
      enqueue("Reversal approved. Edited, matched and unrelated records remain protected.")
    end
    def cleanup
      Portability::Reversal.request_cleanup!(batch: @batch, actor: current_user, session_id: Current.user_session.id, expected_version: params[:version])
      redirect_to admin_import_path(@batch.public_id), status: :see_other, notice: "Owned object cleanup verified."
    end
    def preview_appearance
      Portability::Authority.record_locked(@batch) do
        Portability::Authority.version!(@batch, params[:version])
        raise Portability::Imports::Conflict, "Appearance is not staged." unless @batch.state == "staged" && @batch.report["overlay_id"]
        overlay = ThemeOverlay.find(@batch.report.fetch("overlay_id"))
        receipt = Themes::Manager.preview!(actor: current_user, installation: overlay.theme_installation, overlay: overlay, authentication_token: session[:authentication_token])
        session[:theme_preview] = receipt
      end
      redirect_to root_path, status: :see_other
    end
    private
    def strict_id(value)
      raise Portability::Format::Invalid, "Choose an existing destination identity." unless value.to_s.match?(/\A[1-9][0-9]*\z/)
      Integer(value.to_s, 10)
    end
    def load_batch
      @batch = ImportBatch.where(site: Site.find_by!(singleton_key: 1)).find_by!(public_id: params[:id])
    end
    def load_index
      @contents = Content.order(:id).limit(500)
      @assets = MediaAsset.ready.order(:id).limit(64)
      @authors = User.order(:id).limit(500)
      @batches = ImportBatch.order(id: :desc).limit(25)
      @exports = PortabilityExport.order(id: :desc).limit(25)
      @idempotency_key = SecureRandom.hex(32)
    end
    def load_review
      @authors = User.order(:username).limit(500).pluck(:username, :id)
      @reversal_reasons = Portability::Reversal.reasons(@batch) if %w[staged complete blocked failed needs_approval].include?(@batch.state)
    end
    def enqueue(notice)
      PortabilityImportJob.perform_later(@batch.id)
      redirect_to admin_import_path(@batch.public_id), notice: notice, status: :see_other
    end
  end
end
