# frozen_string_literal: true

module Railpress
  # Observe only the native operator's bounded canary namespace; ordinary jobs
  # retain the original job implementation and argument contract.
  module NativeWorkerProbe
    def perform(id)
      super
      row = PlatformState.find(id)
      deployment = ENV["RAILPRESS_DEPLOYMENT_ID"]
      return unless deployment.to_s.match?(/\A[0-9a-f-]{36}\z/) && row.scope_name == "native-release-probe-#{deployment}" &&
        row.key_name.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
      root = File.join(Railpress::BootstrapState.for_application.root, "release-jobs")
      Dir.mkdir(root, 0o700) unless File.exist?(root) || File.symlink?(root)
      raise "Unsafe native canary directory" unless File.directory?(root) && !File.symlink?(root) &&
        File.stat(root).uid == Process.uid && (File.stat(root).mode & 0o077).zero?
      raise "Native canary retention capacity" if Dir.children(root).length >= 512
      result = { "nonce" => row.key_name, "version" => Railpress::Product::VERSION, "job_contract" => 1,
        "deployment_id" => deployment, "count" => row.payload.fetch("count"), "completed_elapsed" => Railpress::SecurityClock.elapsed }
      # The predecessor already provides the reviewed atomic private file writer.
      Railpress::Releases::Filesystem.atomic(File.join(root, "#{row.key_name}.json"), JSON.generate(result))
    end
  end
end
