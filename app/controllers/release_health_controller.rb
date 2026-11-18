# frozen_string_literal: true

class ReleaseHealthController < ApplicationController
  def show
    expected = ENV["RAILPRESS_NATIVE_PROBE_TOKEN"]
    supplied = request.get_header("HTTP_X_RAILPRESS_PROBE").to_s
    unless expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/) &&
        supplied.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
      return head :not_found
    end
    render json: Releases::HostProbe.call
  end
end
