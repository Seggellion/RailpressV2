module Admin
  class ProtectedFeaturesController < BaseController
    def updates
      authorize!(:inspect_updates)
      if request.post?
        Activity::Recorder.record!(actor: current_user, action: "release.unsupported", outcome: "unsupported")
        render_core_error("Release inspection is not implemented yet (M11). Web permissions never grant arbitrary host commands.", status: :not_implemented)
      end
    end
  end
end
