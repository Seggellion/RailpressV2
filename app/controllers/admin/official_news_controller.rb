module Admin
  class OfficialNewsController < BaseController
    before_action -> { authorize!(:manage_identity) }
    rescue_from OfficialNews::Controls::Conflict, Editorial::Workflow::Conflict do |error|
      @error=error.message;load_panel;render :show, status: :conflict
    end
    rescue_from ArgumentError, OfficialNews::Schema::Invalid do
      @error="No news settings or reviews changed. Check the requested action and official canonical origin."
      load_panel;render :show, status: :unprocessable_entity
    end
    def show
      load_panel
    end
    def update
      allowed=%w[controller action authenticity_token _method commit operation version]
      raise ArgumentError unless (params.keys-allowed).empty?
      OfficialNews::Controls.call(actor: current_user, operation: params[:operation], version: params[:version])
      redirect_to admin_official_news_path, notice: "News settings saved. External refresh uses the worker; local editing remains available.", status: :see_other
    end
    def review
      raise ArgumentError unless (params.keys-%w[controller action authenticity_token commit content_id version]).empty?
      OfficialNews::Provider.review!(actor: current_user, content_id: params[:content_id], expected_version: params[:version])
      redirect_to admin_official_news_path, notice: "The exact approved public Post was reviewed for official metadata.", status: :see_other
    end
    private
    def load_panel
      @site=Site.find_by!(singleton_key: 1)
      @state=OfficialNewsState.find_by(site: @site)
      @news=OfficialNews::Cache.view(@state)
      @posts=@state&.provider_enabled ? Post.publicly_visible.order(id: :desc).limit(20) : []
    end
  end
end
