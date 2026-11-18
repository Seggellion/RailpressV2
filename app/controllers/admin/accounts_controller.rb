module Admin
  class AccountsController < BaseController
    before_action -> { authorize!(:manage_identity) }
    def show
      load_accounts
    end
    def update
      Membership::Policy.configure!(actor: current_user, revision: params[:revision], fields: params.require(:accounts).permit(:membership_mode, :member_registration_enabled, :member_email_required).to_h)
      redirect_to admin_accounts_path, notice: "Membership policy saved; existing Member sessions and pending proofs were revoked. Staff accounts are unchanged.", status: :see_other
    rescue Membership::Conflict
      @error = "Accounts changed in another session. Reload, compare and explicitly save your choice. No policy was overwritten."
      load_accounts
      render :show, status: :conflict
    rescue Membership::Invalid, Membership::Unavailable, ActiveRecord::RecordInvalid
      @error = "Membership was not enabled. Choose a valid policy and ask the host operator to verify each selected provider, or leave registration disabled."
      load_accounts
      render :show, status: :unprocessable_entity
    end
    private
    def load_accounts
      @site = Site.find_by!(singleton_key: 1)
      @delivery_counts = MemberChallenge.where(site: @site).group(:state).count
    end
  end
end
