module Releases
  module Requests
    module_function
    def submit!(actor:, operation:, release_id:, request_id:)
      raise ArgumentError, "Unsupported operator operation" unless (%w[inspect stage cancel] + HostStatus.operations).include?(operation)
      raise ArgumentError, "Invalid release or request identity" unless Railpress::Releases::SHA.match?(release_id.to_s) && Railpress::Releases::UUID.match?(request_id.to_s)
      Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        fresh = User.lock.find(actor.id)
        Identity::Capabilities.require!(fresh, :inspect_updates)
        raise Identity::Capabilities::Denied unless fresh.auth_version == actor.auth_version
        existing = ReleaseRequest.find_by(request_key: request_id)
        if existing
          raise ArgumentError, "Request identity already belongs to another operation" unless existing.actor_id == fresh.id && existing.operation == operation && existing.release_digest == release_id
          return existing
        end
        raise ArgumentError, "Release request queue is full; ask the operator to reconcile it" if ReleaseRequest.where(site: site).count >= 64
        request = ReleaseRequest.create!(site: site, actor: fresh, actor_auth_version: fresh.auth_version,
          operation: operation, release_digest: release_id, request_key: request_id)
        Activity::Recorder.record!(actor: fresh, action: "release.requested", details: { operation: operation, digest: release_id })
        request
      end
    end
    def roots
      path = ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"]
      raise Railpress::Releases::Invalid, "operator_unconfigured" unless path
      # Web reads an operator-published PUBLIC trust document, never private roots or a signer.
      stat = File.lstat(path)
      raise Railpress::Releases::Invalid, "unsafe_public_trust" unless stat.file? && !stat.symlink? && (stat.mode & 0o022).zero? && stat.size <= 65_536
      bytes = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        raise Railpress::Releases::Invalid, "changed_public_trust" unless file.stat.ino == stat.ino && file.stat.dev == stat.dev
        file.read(65_537).to_s
      end
      data = Railpress::Releases.parse(bytes, limit: 65_536)
      Railpress::Releases::Authority.new(data)
    end
    def receipt_for(request)
      return nil unless request.receipt
      envelope = Railpress::Releases.parse(Railpress::Releases.canonical(request.receipt), limit: 65_536)
      Railpress::Releases.keys!(envelope, %w[statement signature])
      statement = envelope.fetch("statement")
      trust = roots
      id = Railpress::Releases.signature!(Railpress::Releases.canonical(statement), envelope["signature"], trust.roots, purpose: "status")
      raise Railpress::Releases::Invalid, "revoked_status_key" if trust.revoked.include?(id)
      if statement["format"] == "railpress.host-result.v1"
        HostStatus.receipt!(statement, request)
        if statement["error"].nil?
          publisher = statement["publisher"]
          raise Railpress::Releases::Invalid, "publisher_status_untrusted" unless trust.roots.dig(publisher, "purpose") == "release" && !trust.revoked.include?(publisher)
        end
        return statement
      end
      raise Railpress::Releases::Invalid, "status_identity" unless statement["format"] == "railpress.operator.v1" &&
        statement["request_id"] == request.request_key && statement["release_id"] == request.release_digest &&
        statement["operation"] == request.operation && statement["revision"] == request.receipt_revision &&
        %w[AVAILABLE PREFLIGHT DOWNLOADING VERIFIED STAGED FAILED_STAGED CANCELLED].include?(statement["state"]) && statement["activation_supported"] == false && statement["installed_version"].is_a?(String) && statement["installed_version"].bytesize <= 80 && Railpress::Releases::SEMVER.match?(statement["installed_version"])
      if statement["error"].nil? && statement["operation"] != "cancel"
        publisher = statement["publisher"]
        raise Railpress::Releases::Invalid, "publisher_status_untrusted" unless trust.roots.dig(publisher, "purpose") == "release" && !trust.revoked.include?(publisher)
      end
      statement
    rescue Railpress::Releases::Invalid, KeyError, TypeError, ArgumentError, SystemCallError, IOError
      { "state" => "UNVERIFIED", "error" => "Operator attestation unavailable; no host success is assumed." }
    end
    def accept!(request:, receipt:)
      request.with_lock do
        if receipt.is_a?(Hash) && receipt.dig("statement", "format") == "railpress.host-result.v1" && request.receipt == receipt &&
            receipt.dig("statement", "revision") == request.receipt_revision
          raise ArgumentError, "unverified receipt" if receipt_for(request)["state"] == "UNVERIFIED"
          return request
        end
        raise ArgumentError, "receipt revision" unless receipt.is_a?(Hash) && receipt.dig("statement", "revision").is_a?(Integer) && receipt["statement"]["revision"] > request.receipt_revision
        request.receipt = receipt
        request.receipt_revision = receipt["statement"]["revision"]
        raise ArgumentError, "unverified receipt" if receipt_for(request)["state"] == "UNVERIFIED"
        request.save!
      rescue StandardError
        request.reload if request.persisted?
        raise
      end
    end
  end
end
