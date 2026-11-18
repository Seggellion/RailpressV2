# frozen_string_literal: true

module Releases
  module HostProbe
    module_function
    def call = Railpress::NativeWebProbe.report
  end
end
