class ContentPreviewsController < ApplicationController
  before_action :require_authentication
  before_action -> { response.set_header("Referrer-Policy", "no-referrer") }
  def show
    credential = session[:editorial_preview] || {}
    raise ActiveRecord::RecordNotFound unless credential["id"].to_s == params[:id].to_s
    record = Editorial::Previews.resolve!(actor: current_user, id: params[:id], token: credential["token"])
    @presenter = ContentPresenter.new(record.content, snapshot: record.snapshot, preview_id: record.id)
    render :show
  end
end
