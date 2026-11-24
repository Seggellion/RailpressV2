# frozen_string_literal: true

module Admin
  class SeoController < BaseController
    before_action -> { authorize!(:execute_seo) }
    before_action :load_site

    def show
      @policy = ::Seo::Policy.decision(site: @site, family: :home)
      @latest = ::Seo::DiagnosticRun.order(id: :desc).first
      @last_clean = ::Seo::DiagnosticRun.where(status: "completed").order(id: :desc).limit(25).find { |run| run.summary["codes"] == [] }
    rescue ActiveRecord::StatementInvalid
      render_core_error("SEO status is unavailable. Check the schema and supported inventory limits.", status: :service_unavailable)
    end

    def sitemap
      @report = ::Seo::SitemapReport.new(site: @site)
    rescue ::Seo::UrlInventory::TooLarge, Nokogiri::XML::SyntaxError
      render_core_error("The sitemap could not be compared. Check inventory limits and cache health.", status: :service_unavailable)
    end

    def indexability
      @policy = ::Seo::Policy.decision(site: @site, family: :home)
      @eligible = ::Seo::UrlInventory.call(site: @site).group_by(&:family).transform_values(&:size)
      @excluded = Content.where.not(id: Content.publicly_visible.select(:id)).group(:status, :visibility).count
      @public_excluded = @policy.indexable? ? 0 : Content.publicly_visible.count
      @redirects = Redirect.order(id: :desc).limit(25)
    rescue ::Seo::UrlInventory::TooLarge
      render_core_error("The current inventory exceeds supported sitemap limits.", status: :service_unavailable)
    end

    def diagnostics
      @runs = ::Seo::DiagnosticRun.order(id: :desc).limit(25)
    end

    def diagnostic
      @run = ::Seo::DiagnosticRun.find(params[:id])
      respond_to do |format|
        format.html do
          @page = params[:page].to_i.clamp(1, 10)
          @targets = @run.diagnostic_targets.order(:position).offset(25 * (@page - 1)).limit(25).to_a
        end
        format.json do
          send_data JSON.pretty_generate(findings), filename: "seo-findings-#{@run.id}.json", type: "application/json"
        end
      end
    end

    def execute
      mode = params[:mode] == "http" ? "http" : "offline"
      run = ::Seo::Diagnostics.start!(actor: current_user, mode: mode)
      redirect_to admin_seo_diagnostic_path(run), notice: "Diagnostic run #{run.id}: #{run.status}.", status: :see_other
    rescue ::Seo::Diagnostics::Invalid
      render_core_error("HTTP checks require operator enablement. Offline checks remain available.", status: :unprocessable_entity)
    end

    private

    def load_site
      @site = Site.find_by!(singleton_key: 1)
    end

    def findings
      @run.diagnostic_targets.order(:position).limit(::Seo::Diagnostics::LIMITS.values.max).filter_map do |target|
        next unless target.url.start_with?("#{@run.origin}/") && target.checked_at

        codes = target.result.fetch("codes", [])
        next if codes.empty?

        { url: target.url, family: target.family, checked_at: target.checked_at.iso8601, codes: codes }
      end
    end
  end
end
