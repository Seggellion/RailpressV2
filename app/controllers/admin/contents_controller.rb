# frozen_string_literal: true

module Admin
  class ContentsController < BaseController
    before_action :load_content, except: [ :index, :new, :create ]
    rescue_from Editorial::Workflow::Conflict do |error|
      @error = error.message
      @submitted = params[:content]&.permit(*Editorial::Workflow::FIELDS)&.to_h
      @content.reload
      prepare_form
      render :edit, status: :conflict
    end
    rescue_from ContentBlocks::Schema::Invalid, Editorial::Workflow::Invalid, Editorial::LocalTime::Invalid, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique do
      @submitted = params[:content]&.permit(*Editorial::Workflow::FIELDS)&.to_h
      @error = "No changes were saved. Check title, unique slug, template, schedule and selected terms."
      @content ||= { "Page" => Page, "Post" => Post }.fetch(params[:kind], Content).new
      @content.reload if @content.persisted?
      prepare_form
      render :edit, status: :unprocessable_entity
    end
    def index
      @contents = Identity::Capabilities.allowed?(current_user, :edit_others) ? Content.all : Content.where(author: current_user)
      @kind = params[:kind] if %w[Page Post].include?(params[:kind])
      @query = params[:q].to_s.first(160)
      @status = params[:status] if %w[draft pending published scheduled trashed].include?(params[:status])
      @contents = @contents.where(type: @kind) if @kind
      @contents = @contents.where(status: @status) if @status
      @contents = @contents.where("LOWER(title) LIKE ?", "%#{Content.sanitize_sql_like(@query.downcase)}%") if @query.present?
      @page = [ [ params[:page].to_i, 1 ].max, 400 ].min
      rows = @contents.includes(:author).order(updated_at: :desc, id: :desc).offset((@page - 1) * 25).limit(26).to_a
      @more = rows.length > 25 && @page < 400
      @contents = rows.first(25)
    end
    def new
      kind = params[:kind] == "Post" ? Post : Page
      @content = kind.new(visibility: "public", template_key: "standard")
      prepare_form
      render :edit
    end
    def create
      @content = Editorial::Workflow.create!(actor: current_user, kind: params[:kind], attributes: content_params)
      redirect_to edit_admin_content_path(@content), notice: "Draft created.", status: :see_other
    end
    def edit
      prepare_form
    end
    def update
      if params[:editorial_action] == "reassign"
        Editorial::Authorship.transfer!(actor: current_user, content: @content, author_id: params[:new_author_id], version: params[:version])
        return redirect_to edit_admin_content_path(@content), notice: "Working-copy author transferred. Approved public snapshots and history were retained; scheduled approval was withdrawn.", status: :see_other
      end
      Editorial::Workflow.update!(actor: current_user, content: @content, expected_version: params[:version],
        attributes: content_params, event: params[:editorial_action].presence || "save", revision_id: params[:revision_id])
      redirect_to edit_admin_content_path(@content), notice: "#{(params[:editorial_action].presence || 'save').humanize} completed. Preview uses the saved working copy.", status: :see_other
    end
    def preview
      record, token = Editorial::Previews.issue!(actor: current_user, content: @content)
      session[:editorial_preview] = { "id" => record.id, "token" => token }
      redirect_to content_preview_path(record), status: :see_other
    end
    def revisions
      @page = [ [ params[:page].to_i, 1 ].max, 400 ].min
      scope = @content.content_revisions.includes(:actor).order(number: :desc)
      @selected = scope.find_by(id: params[:revision])
      rows = scope.offset((@page - 1) * 25).limit(26).to_a
      @more = rows.length > 25 && @page < 400
      @revisions = rows.first(25)
      @selected ||= @revisions.first
    end

    private
    def core_headers
      super
      response.set_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
    end
    def load_content
      @content = Content.find(params[:id])
      raise Identity::Capabilities::Denied unless Identity::Capabilities.can_edit_content?(current_user, author_id: @content.author_id)
    end
    def prepare_form
      @terms = Term.includes(:taxonomy).order(:name)
      @publisher = Identity::Capabilities.allowed?(current_user, :publish_others)
      retained = @content.persisted? ? @content.media_references.where(stage: "draft").pluck(:media_asset_id) : []
      @media_options = MediaLibrary::Policy.scope(current_user).ready.or(MediaAsset.ready.where(id: retained)).order(:title).map { |asset| [ (asset.author_id == current_user.id || Identity::Capabilities.allowed?(current_user, :manage_media)) ? asset.title : (@content.media_details.to_h.dig(asset.id.to_s, "title") || "Retained image"), asset.id ] }
      @site = Site.find_by!(singleton_key: 1)
    end
    def content_params
      raw = params.fetch(:content, ActionController::Parameters.new)
      attributes = raw.permit(*Editorial::Workflow::FIELDS, :schedule_local, :featured_media_id, :add_block, :pattern_key,
        term_ids: [], blocks: [ :type, :text, :level, :html, :media_id, :heading, :label, :url, :quote, :attribution, :address, :email, :phone, :caption, { media_ids: [], items: [ :heading, :text, :question, :answer ] } ]).to_h
      attributes["blocks"] ||= [] if raw[:blocks_present] == "1"
      %w[remove_block move_block add_item].each { |key| attributes[key] = params[key] if params[key].present? }
      attributes
    end
  end
end
