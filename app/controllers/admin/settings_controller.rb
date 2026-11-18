# frozen_string_literal: true

module Admin
  class SettingsController < BaseController
    before_action -> { authorize!(:manage_identity) }
    def edit
      @site = Site.find_by!(singleton_key: 1)
    end
    def update
      @site = Site.find_by!(singleton_key: 1)
      @site.with_lock do
        current_user.lock!
        Identity::Capabilities.require!(current_user, :manage_identity)
        attributes = params.require(:site).permit(:title, :tagline, :canonical_origin, :locale, :timezone, :home_mode, :indexing_enabled, :organization_name).to_h
        attributes["indexing_enabled"] = attributes["indexing_enabled"] == "1"
        @site.update!(attributes)
        Activity::Recorder.record!(actor: current_user, action: "identity.site_updated", subject: @site)
      end
      redirect_to admin_settings_path, notice: "Site identity saved.", status: :see_other
    rescue ActiveRecord::RecordInvalid
      @error = "Review the site settings; no changes were saved."
      render :edit, status: :unprocessable_entity
    end
  end
end
