module Admin
  class ReadinessController < BaseController
    before_action -> { authorize!(:view_readiness) }
    rescue_from Readiness::Assessment::Conflict do |error|
      @error = error.message
      load_report
      render :show, status: :conflict
    end
    def show
      load_report
    end
    def create
      run = Readiness::Assessment.request!(actor: current_user)
      redirect_to admin_readiness_path, notice: "Assessment #{run.id} is #{run.state}. Reload to see its dated observations.", status: :see_other
    end
    def destroy
      run = ReadinessRun.where(site: Site.find_by!(singleton_key: 1)).find(params[:id])
      Readiness::Assessment.cancel!(actor: current_user, run: run, version: params[:version])
      redirect_to admin_readiness_path, notice: "Assessment cancelled. You can request a new observation.", status: :see_other
    end
    private
    def load_report
      @run = ReadinessRun.order(id: :desc).first
      @fresh = Readiness::Assessment.current?(@run)
    end
  end
end
