module Admin
  class BaseController < ApplicationController
    layout "admin"
    before_action :require_authentication
    before_action -> { authorize!(:admin) }
    private
    def core_headers
      super
      response.set_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
    end
  end
end
