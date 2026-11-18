# frozen_string_literal: true

module Admin
  class UsersController < BaseController
    before_action -> { authorize!(:manage_users) }
    rescue_from Identity::ManageUsers::LastOwner do
      render_core_error("The last owner cannot be removed or demoted.", status: :conflict)
    end
    rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotDestroyed do
      render_core_error("The requested account change is invalid.", status: :unprocessable_entity)
    end

    def index
      @users = User.order(:id)
    end
    def create
      attributes = params.require(:user).permit(:username, :email, :password, :password_confirmation, :role).to_h.symbolize_keys
      Identity::ManageUsers.create!(actor: current_user, attributes: attributes)
      redirect_to admin_users_path, notice: "Account created.", status: :see_other
    end
    def update
      user = User.find(params[:id])
      Identity::ManageUsers.change_role!(actor: current_user, user: user, role: params.require(:user).permit(:role)[:role])
      reset_session if user.id == current_user.id
      redirect_to login_path_if_self(user), status: :see_other
    end
    def destroy
      user = User.find(params[:id])
      self_change = user.id == current_user.id
      Identity::ManageUsers.remove!(actor: current_user, user: user)
      reset_session if self_change
      redirect_to(self_change ? login_path : admin_users_path, status: :see_other)
    end

    private
    def login_path_if_self(user)
      user.id == current_user.id ? login_path : admin_users_path
    end
  end
end
