module Admin
  class ActivityController < BaseController
    def index
      @page = [ [ params[:page].to_i, 1 ].max, 40 ].min
      @events = Activity::Recorder.scope_for(current_user).order(id: :desc).offset((@page - 1) * 25).limit(26).to_a
      @more = @events.length > 25
      @events = @events.first(25)
    end
  end
end
