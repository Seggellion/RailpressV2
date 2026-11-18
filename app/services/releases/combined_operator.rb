# frozen_string_literal: true

module Releases
  # Native operator composition, not a web job or shell interface. Required
  # admissions are the host's existing reviewed UTC/native approval adapters.
  class CombinedOperator
    def initialize(staging:, host:, prepare_stage:, approve_promote:, signer:, health:, lock_root:)
      @staging, @host, @prepare_stage, @approve_promote, @signer, @health = staging, host, prepare_stage, approve_promote, signer, health
      @lock_root = Railpress::Releases::Filesystem.directory!(lock_root, private: true)
    end
    def perform(request)
      Railpress::NativeHost.uuid!(request.request_key)
      path = File.join(@lock_root, "combined-#{request.request_key}.lock")
      File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise Combined::Conflict, "Combined operation is already running." unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          perform_locked(request)
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end
    def perform_locked(request)
      plan = Combined.selection(request)
      return Combined.result(request) if plan["result"]
      actor = Combined.validate!(request, plan)
      state = "FAILED_STAGED"
      @prepare_stage.call(@staging, request)
      staged = @staging.stage(request_id: request.request_key, release_id: request.release_digest)
      trust = Requests.roots
      signer_id = Railpress::Releases.signature!(Railpress::Releases.canonical(staged.fetch("statement")), staged.fetch("signature"), trust.roots, purpose: "status")
      raise Combined::Conflict, "Staging receipt is not bound to this request." if trust.revoked.include?(signer_id) ||
        staged.dig("statement", "request_id") != request.request_key || staged.dig("statement", "release_id") != request.release_digest
      raise Combined::Conflict, "Verified staging did not complete." unless staged.dig("statement", "state") == "STAGED" && staged.dig("statement", "error").nil?
      Combined.validate!(request, plan)
      @approve_promote.call(@host, request)
      state = "CORE_UPDATE_FAILED"
      receipt = @host.perform(request.request_key)
      Requests.accept!(request: request, receipt: receipt)
      core = Requests.receipt_for(request.reload)
      raise Combined::Conflict, "Core operator did not report this exact active release." unless core["state"] == "ACTIVE" && core["error"].nil? && core["active_release"] == request.release_digest
      state = "CORE_UPDATED_THEME_REVIEW_REQUIRED"
      raise Combined::Conflict, "Post-update core health failed." unless @health.call(request.release_digest)
      actor = Combined.validate!(request, plan)
      if plan["selected_theme_id"]
        Site.transaction do
          Site.find(request.site_id).lock!; actor.lock!
          Combined.validate!(request, plan)
          target = ThemeInstallation.find(plan["selected_theme_id"])
          raise Combined::Conflict, "Selected theme identity changed." unless Combined.theme_identity(target) == plan["selected_theme"]
          Themes::Manager.activate!(actor: actor, installation: target, overlay: ThemeOverlay.find(plan["selected_overlay_id"]),
            version: plan["expected_theme_revision"])
        end
      end
      raise Combined::Conflict, "Post-update theme health failed." unless @health.call(request.release_digest)
      finish(request, plan, "COMPLETE", nil)
    rescue StandardError => error
      code = error.is_a?(Railpress::Releases::Invalid) && error.message.match?(/\A[a-z_]{1,100}\z/) ? error.message : "combined_update_stopped"
      finish(request, plan, state || "FAILED_STAGED", code) if plan && plan["format"] == Combined::PROTOCOL
    end
    def finish(request, plan, state, error)
      statement = { "format" => Combined::PROTOCOL, "request_id" => request.request_key, "release_id" => request.release_digest,
        "selection_sha256" => Digest::SHA256.hexdigest(Railpress::Releases.canonical(plan.except("result"))), "state" => state, "error" => error,
        "active_theme" => Combined.theme_identity(ThemeState.find_by(site_id: request.site_id)&.active_installation),
        "automatic_database_restore" => false }
      trust = Requests.roots
      raise Railpress::Releases::Invalid, "status_signer_untrusted" unless trust.roots.dig(Railpress::Releases.key_id(@signer), "purpose") == "status" && !trust.revoked.include?(Railpress::Releases.key_id(@signer))
      envelope = Railpress::NativeHost.sign(statement, @signer)
      Site.transaction do
        Site.find(request.site_id).lock!
        current = Combined.selection(request)
        raise Combined::Conflict, "Combined plan changed." unless current.except("result") == plan.except("result")
        return Combined.result(request) if current["result"]
        Catalog.save!(Combined.key(request.request_key), current.merge("result" => envelope))
      end
      statement
    end
  end
end
