module Admin
  class ToolsController < BaseController
    before_action -> { authorize!(:manage_identity) }
    def imports
    end
  end
end
