module Admin
  class DashboardController < BaseController
    rescue_from Editorial::Workflow::Invalid, ActiveRecord::RecordInvalid do
      @error="No draft was saved. Enter a title of 1–200 characters and at most 200,000 characters of text."
      load_dashboard
      render :index, status: :unprocessable_entity
    end
    rescue_from Editorial::Workflow::Conflict do |error|
      @error=error.message
      load_dashboard
      render :index, status: :conflict
    end
    def index
      load_dashboard
    end
    def create
      raise Editorial::Workflow::Invalid unless params.keys.map(&:to_s).all? { |key|%w[controller action authenticity_token commit utf8 draft].include?(key) }
      raw=params.require(:draft)
      raise Editorial::Workflow::Invalid unless (raw.keys-%w[request_key version kind title body]).empty?
      content=Dashboard::QuickDraft.call(actor: current_user, request_key: raw[:request_key], expected_version: raw[:version],
        kind: raw[:kind], title: raw[:title], body: raw[:body])
      redirect_to edit_admin_content_path(content), notice: "Private draft saved. Review it before publishing.", status: :see_other
    end
    private
    def load_dashboard
      @dashboard=Dashboard::Overview.new(actor: current_user)
      @site=@dashboard.site
      @drafts=@dashboard.drafts
      @activity=@dashboard.activity
      key=params.dig(:draft, :request_key).to_s
      @draft_key=key.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/) ? key : SecureRandom.uuid
    end
  end
end
