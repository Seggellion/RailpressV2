module Admin
  class MenusController < BaseController
    before_action -> { authorize!(:manage_menus) }
    before_action :load_menu, only: [ :edit, :update, :destroy, :preview ]
    rescue_from Navigation::Mutation::Conflict do |error|
      @error = error.message
      @submitted = params[:tree].to_s
      prepare
      render(@menu ? :edit : :index, status: :conflict)
    end
    rescue_from Navigation::Mutation::Invalid, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, JSON::ParserError, ArgumentError do |error|
      @error = error.is_a?(Navigation::Mutation::Invalid) ? error.message : "No changes saved. Check the selected targets, tree and revision."
      prepare
      render(@menu ? :edit : :index, status: :unprocessable_entity)
    end
    def index
      prepare
    end
    def create
      menu = Navigation::Mutation.call(actor: current_user, expected_state: params[:state_version], operation: "create", payload: { "name" => params[:name].to_s })
      redirect_to edit_admin_menu_path(menu), notice: "Menu created. Add links to build your draft.", status: :see_other
    end
    def edit
      prepare
    end
    def update
      operation = params[:operation].to_s
      raise Navigation::Mutation::Invalid, "Unknown editor command." unless %w[rename add update remove move reorder reparent assign publish undo].include?(operation)
      raw = params.fetch(:item, ActionController::Parameters.new).permit(:label, :kind, :content_id, :term_id, :url).to_h
      %w[content_id term_id].each { |key| raw[key] = raw[key].present? ? Navigation::Mutation.integer(raw[key]) : nil if raw.key?(key) }
      raw["url"] = nil if raw["kind"] != "Custom" && raw.key?("url")
      payload = { "name" => params[:name].to_s, "key" => params[:key].to_s, "direction" => params[:direction].to_s,
        "item" => raw, "locations" => Array(params[:locations]).reject(&:blank?), "revision_id" => params[:revision_id] }
      if operation == "add" && params[:target].present?
        kind, id = params[:target].to_s.split(":", 2)
        target = kind == "Term" ? Term.find(id) : Content.publicly_visible.where(type: kind).find(id)
        label = kind == "Term" ? target.name : target.published_snapshot.fetch("title")
        payload["item"] = { "kind" => kind, "label" => label.truncate(120, omission: "…"), kind == "Term" ? "term_id" : "content_id" => target.id }
      end
      if %w[reorder reparent].include?(operation)
        raise Navigation::Mutation::Invalid, "Tree payload is too large." if params[:tree].to_s.bytesize > 16_384
        payload["tree"] = JSON.parse(params[:tree].to_s)
      end
      Navigation::Mutation.call(actor: current_user, menu: @menu, expected_version: params[:version], expected_state: params[:state_version], operation: operation, payload: payload)
      notice = case operation
      when "publish" then "Navigation published atomically."
      when "undo" then "Previous menu and publication state restored."
      else "Draft change saved. Public navigation is unchanged until publish."
      end
      redirect_to edit_admin_menu_path(@menu), notice: notice, status: :see_other
    end
    def destroy
      Navigation::Mutation.call(actor: current_user, menu: @menu, expected_version: params[:version], expected_state: params[:state_version], operation: "delete")
      redirect_to edit_admin_menu_path(@menu), notice: "Menu withdrawn. Undo is available until the next navigation change.", status: :see_other
    end
    def preview
      session[:navigation_preview] = Navigation::Preview.issue(actor: current_user, menu: @menu, authentication_token: session[:authentication_token])
      redirect_to root_path, status: :see_other
    end
    def stop_preview
      Navigation::Preview.revoke(actor: current_user, authentication_token: session[:authentication_token], credential: session[:navigation_preview])
      session.delete(:navigation_preview)
      redirect_to admin_menus_path, status: :see_other
    end
    private
    def core_headers
      super
      response.set_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
    end
    def load_menu
      @menu = Menu.where(site: Site.find_by!(singleton_key: 1)).find(params[:id])
    end
    def prepare
      @site = Site.find_by!(singleton_key: 1)
      @menu&.reload
      @menus = Menu.where(site: @site).order(:name, :id)
      @state_version = Navigation::Mutation.generation(@site)
      @locations = Navigation::Mutation.declared(@site)
      @assigned = @menu ? MenuLocation.where(site: @site, draft_menu_id: @menu.id).map { |row| "#{row.theme_key}:#{row.key}" } : []
      @source_query = params[:source_query].to_s.strip.first(160)
      @sources = Content.publicly_visible
      @terms = Term.includes(:taxonomy)
      if @source_query.present?
        pattern = "%#{Content.sanitize_sql_like(@source_query)}%"
        @sources = @sources.where("LOWER(public_search_text) LIKE LOWER(?)", pattern)
        @terms = @terms.where("LOWER(name) LIKE LOWER(?)", pattern)
      end
      @sources = @sources.order(:type, :id).limit(200)
      @terms = @terms.order(:name).limit(200)
      @rows = @menu ? Navigation::Tree.ordered(@menu.tree) : []
      @latest = @menu&.menu_revisions&.order(number: :desc)&.first
    end
  end
end
