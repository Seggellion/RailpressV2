module Admin
  class SessionStatesController < BaseController
    def show
      response.set_header("X-Railpress-Session-Binding", helpers.admin_session_binding)
      head :no_content
    end
  end
end
