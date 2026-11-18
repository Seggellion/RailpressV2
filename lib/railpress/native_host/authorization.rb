# frozen_string_literal: true

module Railpress
  module NativeHost
    class Authorization
      def initialize(config, store, clock:)
        @config, @store, @time = config, store, Releases::ReleaseTime.new(clock)
      end
      def prepare!(state, request, confirmation:, snapshot_id: nil, loss_fingerprint: nil)
        raise Error, "deployment_confirmation" unless confirmation == @config.data["deployment_id"]
        if %w[SWITCHING VERIFYING RESTORING RESTORE_REQUIRED].include?(request["phase"])
          pending = state["restore_pending"]
          raise Error, "reconcile_required" unless request["operation"] == "restore" && pending &&
            pending.values_at("snapshot_id", "release_id", "accepted_loss_fingerprint") == [ snapshot_id, request["release_id"], loss_fingerprint ]
        end
        raise Error, "stale_host_generation" unless request["expected_generation"] == state["generation"]
        if request["operation"] == "restore"
          NativeHost.uuid!(snapshot_id)
          Releases.identity!(loss_fingerprint)
          request["snapshot_id"], request["accepted_loss_fingerprint"] = snapshot_id, loss_fingerprint
        else
          raise Error, "restore_arguments_only" if snapshot_id || loss_fingerprint
        end
        request["challenge"] = @time.challenge
        request["authorized_generation"] = state["generation"]
        request["native_approved"] = true
        @store.persist(state)
        request["challenge"]
      end
      def verify!(state, request, manifest, trust)
        raise Error, "native_approval_required" unless request["native_approved"] &&
          request["authorized_generation"] == state["generation"] && request["challenge"].is_a?(Hash)
        receipt = NativeHost.load_document(@config.path("receipts", "#{request['id']}.json"), maximum: 8192)
        utc = @time.verify!(request["challenge"], receipt, trust, state)
        id = request["release_id"]
        if utc >= manifest["expires_at"]
          state["expired"] |= [ id ]
          @store.persist(state)
          raise Error, "manifest_expired"
        end
        raise Error, "manifest_expired" if state["expired"].include?(id)
        raise Error, "manifest_prepublication" if utc < manifest["published_at"]
        true
      end
    end
  end
end
