module Admin
  class TermsController < BaseController
    before_action -> { authorize!(:publish_others) }
    def index
      @kind = params[:kind] == "tag" ? "tag" : "category"
      @terms = Term.joins(:taxonomy).includes(:taxonomy).where(taxonomies: { kind: @kind }).order(:name).limit(500)
    end
    def create
      Editorial::Terms.create!(actor: current_user, kind: params[:kind], name: params[:name], slug: params[:slug])
      redirect_to admin_terms_path(kind: params[:kind]), notice: "Term created.", status: :see_other
    rescue Editorial::Workflow::Invalid, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      @error = "Use a unique category/tag slug and a name."
      @kind = params[:kind] == "tag" ? "tag" : "category"
      @terms = Term.joins(:taxonomy).includes(:taxonomy).where(taxonomies: { kind: @kind }).order(:name).limit(500)
      render :index, status: :unprocessable_entity
    end
  end
end
