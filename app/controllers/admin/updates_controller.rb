module Admin
  class UpdatesController < BaseController
    before_action -> { authorize!(:inspect_updates) }
    def index
      @requests = ReleaseRequest.where(site: Site.find_by!(singleton_key: 1)).order(id: :desc).limit(64)
      @configured = ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"].present?
      @host_status = ::Releases::HostStatus.read
      @host_operations = ::Releases::HostStatus.operations
      @theme = ThemeState.find_by(site: Site.find_by!(singleton_key: 1))&.active_installation
      @catalog = ::Releases::Catalog.view
      @check_settings = ::Releases::Catalog.settings
      @combined_supported = ::Releases::Combined.capable?
      @theme_choices = @catalog["candidate"] ? ::Releases::Combined.choices(@catalog["candidate"]["manifest"]) : []
      @local_theme_updates = @theme ? ThemeInstallation.where(site_id: @theme.site_id, theme_key: @theme.theme_key, status: "validated").limit(32).filter_map { |item|
        next unless Railpress::Releases.compare_versions(item.version, @theme.version).positive?
        begin
          item if Themes::Storage.load(item).manifest["theme_api"] == Railpress::Product::THEME_API
        rescue Railpress::ThemePackage::Invalid
          @theme_review_required = true
          nil
        end
      } : []
    end
    def checks
      raise ArgumentError unless (params.keys - %w[enabled channel authenticity_token controller action commit utf8]).empty?
      ::Releases::Catalog.configure!(actor: current_user, enabled: params[:enabled] == "1", channel: params[:channel])
      redirect_to admin_updates_path, status: :see_other, notice: "Release check preference saved. Checks run in the background."
    rescue ArgumentError
      render_core_error("Release check preference was rejected.", status: :unprocessable_entity)
    end
    def combined
      raise ArgumentError unless (params.keys - %w[release_id request_id theme_id authenticity_token controller action commit utf8]).empty?
      ::Releases::Combined.submit!(actor: current_user, release_id: params[:release_id], request_id: params[:request_id], theme_id: params[:theme_id])
      redirect_to admin_updates_path, status: :see_other, notice: "Exact update selection recorded for the qualified native operator. Check its verified receipt for completion."
    rescue ::Releases::Combined::Conflict, Railpress::Releases::Invalid, ArgumentError
      render_core_error("Update blocked. Reload metadata, preview the selected theme, and verify the host, backup and time requirements.", status: :unprocessable_entity)
    end
    def create
      unless ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"].present?
        Activity::Recorder.record!(actor: current_user, action: "release.unsupported", outcome: "unsupported")
        return render_core_error("UNSUPPORTED: a separately provisioned native operator and public trust policy are required.", status: :not_implemented)
      end
      allowed = %w[operation release_id request_id authenticity_token utf8 commit controller action]
      raise ArgumentError, "Only bounded release identities and operations are accepted" unless (params.keys - allowed).empty?
      ::Releases::Requests.submit!(actor: current_user, operation: params[:operation] || "stage", release_id: params[:release_id], request_id: params[:request_id])
      redirect_to admin_updates_path, status: :see_other, notice: "Request queued for the native operator. No running release was changed."
    rescue ArgumentError, ActiveRecord::RecordInvalid
      render_core_error("Release request was rejected. Reload Updates and use the displayed supported operation.", status: :unprocessable_entity)
    end
  end
end
