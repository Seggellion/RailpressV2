# frozen_string_literal: true

module Railpress
  module NativeHost
    class Plan
      FAMILIES = %w[home page post archive taxonomy search empty not_found pagination sitemap robots media protected].freeze
      def initialize(config) = @config = config
      def load!(id, trust:, trust_state:)
        Releases.identity!(id)
        directory = F.directory!(@config.path("inbox", id), private: true)
        manifest = Releases::Manifest.validate!(NativeHost.load_document(File.join(directory, "manifest.json")))
        raise Error, "manifest_identity" unless Digest::SHA256.hexdigest(Releases.canonical(manifest)) == id
        signature = NativeHost.load_document(File.join(directory, "signature.json"), maximum: 4096)
        publisher = trust.verify!(Releases.canonical(manifest), signature, trust_state, purpose: "release")
        envelope = NativeHost.load_document(File.join(directory, "native-plan.json"), maximum: 65_536)
        Releases.keys!(envelope, %w[statement signature])
        plan = envelope.fetch("statement")
        signer = trust.verify!(Releases.canonical(plan), envelope["signature"], trust_state, purpose: "release")
        raise Error, "plan_publisher" unless signer == publisher
        Releases.keys!(plan, %w[format release_id predecessors expand contract routes])
        raise Error, "native_plan_identity" unless plan["format"] == "railpress.native-plan.v1" && plan["release_id"] == id
        raise Error, "native_predecessors" unless plan["predecessors"].is_a?(Array) && plan["predecessors"].length <= 16
        plan["predecessors"].each { |value| Releases.identity!(value) }
        contract = plan["contract"]
        Releases.keys!(contract, %w[schema write jobs theme_api])
        contract.each_value { |value| Releases.integer!(value, 1, 100_000) }
        Schema.new(@config).revert_eligible!(manifest, contract)
        Schema.new(@config).validate!(plan["expand"]) if plan["expand"]
        if plan["expand"]
          raise Error, "expand_contract" unless plan["expand"]["schema_to"] == contract["schema"] && plan["expand"]["write_contract"] == contract["write"]
        end
        routes = plan["routes"]
        raise Error, "native_route_matrix" unless routes.is_a?(Array) && routes.length.between?(1, 32)
        routes.each do |row|
          Releases.keys!(row, %w[path status family])
          raise Error, "native_probe_path" unless row["path"].is_a?(String) && row["path"].bytesize.between?(1, 512) &&
            row["path"].start_with?("/") && !row["path"].start_with?("//") && !row["path"].match?(/[\x00-\x20\x7f#]/) &&
            !row["path"].include?("://") && [ 200, 301, 303, 404, 410 ].include?(row["status"]) && FAMILIES.include?(row["family"])
        end
        [ manifest, plan, publisher ]
      end
      def tree!(id, manifest)
        path = @config.release(id)
        raise Error, "release_completion" unless F.read(File.join(path, ".complete"), maximum: 64) == id
        Releases::Bundle.verify_tree!(path, manifest)
      end
    end
  end
end
