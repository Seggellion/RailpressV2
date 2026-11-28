# frozen_string_literal: true

module NeutralProbe
  class Engine < ::Rails::Engine
    isolate_namespace NeutralProbe
    config.root = File.expand_path("../..", __dir__)

    initializer "neutral_probe.worker_identity" do
      if Rails.env.test? && ENV["RAILPRESS_PROCESS_ROLE"] == "worker"
        puts "NEUTRAL_WORKER #{Process.pid} #{Railpress::Extensions.registry.fingerprint}"
        $stdout.flush
      end
    end
  end
end
