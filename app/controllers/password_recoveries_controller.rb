# frozen_string_literal: true

class PasswordRecoveriesController < ApplicationController
  def new
  end
  def create
    allowed = AuthenticationThrottle.consume?(scope: "recovery-ip", identity: client_address, limit: 5, window: 1.hour)
    return render_core_error("Too many requests. Try again later.", status: :too_many_requests) unless allowed
    Identity::PasswordRecovery.request!(params[:identifier].to_s)
    @message = "If recovery email is available for that account, instructions will be sent. Otherwise, use host-operator recovery."
    render :new, status: :accepted
  end
  def edit
  end
  def update
    allowed = AuthenticationThrottle.consume?(scope: "reset-ip", identity: client_address, limit: 10, window: 10.minutes)
    return render_core_error("Too many attempts. Try again later.", status: :too_many_requests) unless allowed
    Identity::PasswordRecovery.complete!(token: params[:recovery_token], password: params[:password], confirmation: params[:password_confirmation])
    reset_session
    redirect_to login_path, notice: "Password changed. All earlier sessions are revoked; sign in again.", status: :see_other
  rescue Identity::PasswordRecovery::InvalidToken, ActiveRecord::RecordInvalid
    @error = "The token is invalid/expired, or the password does not meet the requirements."
    render :edit, status: :unprocessable_entity
  end
end
