# frozen_string_literal: true

class HealthController < ActionController::Base
  def show
    response.set_header("Cache-Control", "no-store")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    render plain: "OK"
  end
end
