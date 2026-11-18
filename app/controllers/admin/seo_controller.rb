module Admin
  class SeoController < BaseController
    before_action -> { authorize!(:execute_seo) }
    def show
      @site = Site.find_by!(singleton_key: 1)
      @policy = ::Seo::Policy.decision(site: @site, family: :home)
      @runs = ::Seo::DiagnosticRun.order(id: :desc).limit(25)
      @inventory_count = ::Seo::UrlInventory.call(site: @site).length
      @redirects = Redirect.order(id: :desc).limit(25)
    rescue ActiveRecord::StatementInvalid, ::Seo::UrlInventory::TooLarge
      @error = "SEO status is unavailable. Check the schema and supported inventory limits."
      render_core_error(@error, status: :service_unavailable)
    end
    def execute
      mode = params[:mode] == "http" ? "http" : "offline"
      run = ::Seo::Diagnostics.start!(actor: current_user, mode: mode)
      redirect_to admin_seo_path, notice: "Diagnostic run #{run.id}: #{run.status}. The worker reports local correctness, not search-engine indexing.", status: :see_other
    rescue ::Seo::Diagnostics::Invalid
      render_core_error("HTTP checks require operator enablement. Offline checks remain available.", status: :unprocessable_entity)
    end
  end
end
