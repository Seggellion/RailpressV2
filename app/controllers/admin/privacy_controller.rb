module Admin
  class PrivacyController < BaseController
    before_action -> { authorize!(:manage_identity) }
    def show
      @site = Site.find_by!(singleton_key: 1)
      @posture = Privacy::Diagnostics.read(@site)
    end
    def update
      value = params[:privacy].is_a?(ActionController::Parameters) ? params[:privacy][:enabled] : nil
      Privacy::Policy.configure!(actor: current_user, revision: params[:revision], value: value)
      redirect_to admin_privacy_path, status: :see_other, notice: "Anonymous browsing policy saved. Authentication security remains enabled."
    rescue Privacy::Conflict
      @error = "Privacy settings changed in another session. Reload and review before saving."
      show
      render :show, status: :conflict
    rescue Privacy::Invalid
      @error = "Choose a valid anonymous browsing policy. No change was saved."
      show
      render :show, status: :unprocessable_entity
    end
  end
end
