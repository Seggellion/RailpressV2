# frozen_string_literal: true

module Railpress
  module Releases
    class Operator
      attr_reader :journal
      def initialize(root:, context:, clock:, signer:, capacity: Filesystem.method(:capacity!), progress: nil)
        @progress = progress
        @journal = Journal.new(root, on_transition: ->(state, request) { notify_progress(state, request) })
        @context, @clock, @signer, @capacity = context, clock, signer, capacity
        @time = ReleaseTime.new(clock)
        %w[inbox staging receipts].each { |name| Filesystem.directory!(File.join(root, name), private: true) }
      end
      def authority
        Authority.new(Releases.parse(Filesystem.read(File.join(journal.root, "trust.json"), maximum: 65_536), limit: 65_536))
      end
      def metadata(release_id)
        Releases.identity!(release_id)
        path = Filesystem.directory!(File.join(journal.root, "inbox", release_id), private: true)
        manifest = Manifest.validate!(Releases.parse(Filesystem.read(File.join(path, "manifest.json"), maximum: 1_048_576)))
        raise Invalid, "manifest_identity" unless Digest::SHA256.hexdigest(Releases.canonical(manifest)) == release_id
        signature = Releases.parse(Filesystem.read(File.join(path, "signature.json"), maximum: 4096), limit: 4096)
        [ manifest, signature, path ]
      end
      def inspect(request_id:, release_id:)
        execute(request_id, release_id, "inspect") do |state, request, manifest, _path, _trust|
          journal.transition!(state, request, "AVAILABLE") if request["state"] == "IDLE"
        end
      end
      def challenge(request_id:)
        raise Invalid, "request_id" unless UUID.match?(request_id.to_s)
        journal.transaction do |state|
          request = state.fetch("requests").fetch(request_id) { raise Invalid, "unknown_request" }
          raise Invalid, "request_cancelled" if request["state"] == "CANCELLED"
          request["challenge"] = @time.challenge
          request["challenge"]
        end
      end
      def stage(request_id:, release_id:)
        execute(request_id, release_id, "stage") do |state, request, manifest, path, trust|
          raise Invalid, "request_cancelled" if request["state"] == "CANCELLED"
          destination = File.join(journal.root, "staging", release_id)
          if request["state"] == "STAGED"
            raise Invalid, "stage_identity" unless Filesystem.read(File.join(destination, ".complete"), maximum: 64) == release_id
            Bundle.verify_tree!(destination, manifest)
            next
          end
          challenge = request["challenge"]
          raise Invalid, "trusted_utc_required" unless challenge
          receipt = Releases.parse(Filesystem.read(File.join(journal.root, "receipts", "#{request_id}.json"), maximum: 8192), limit: 8192)
          authorize_time!(state, manifest, release_id, challenge, receipt, trust)
          Manifest.compatible!(manifest, @context)
          channel = manifest["channel"]
          accepted = state["sequence"][channel]
          if accepted && manifest["sequence"] <= accepted["sequence"]
            raise Invalid, "manifest_replay" unless accepted == { "sequence" => manifest["sequence"], "release_id" => release_id, "request_id" => request_id }
          end
          state["sequence"][channel] = { "sequence" => manifest["sequence"], "release_id" => release_id, "request_id" => request_id }
          journal.persist(state)
          journal.transition!(state, request, "AVAILABLE") if request["state"] == "IDLE"
          if %w[PREFLIGHT DOWNLOADING VERIFIED].include?(request["state"])
            journal.transition!(state, request, "FAILED_STAGED", detail: "interrupted_before_promotion")
          end
          journal.transition!(state, request, "PREFLIGHT")
          journal.transition!(state, request, "DOWNLOADING")
          # This qualified adapter consumes a fixed operator-populated local inbox. No network or URL input.
          package = File.join(path, "package.tar.gz")
          journal.transition!(state, request, "VERIFIED") if verified_package?(package, manifest)
          if File.exist?(destination) || File.symlink?(destination)
            raise Invalid, "stage_identity" unless Filesystem.read(File.join(destination, ".complete"), maximum: 64) == release_id
            Bundle.verify_tree!(destination, manifest)
          else
            Bundle.extract!(package, destination, manifest, capacity: @capacity)
          end
          final_trust = authority
          final_trust.apply!(state)
          journal.persist(state)
          final_manifest, final_signature, = metadata(release_id)
          final_trust.verify!(Releases.canonical(final_manifest), final_signature, state, purpose: "release")
          authorize_time!(state, final_manifest, release_id, challenge, receipt, final_trust)
          journal.transition!(state, request, "STAGED")
        end
      end
      def cancel(request_id:, release_id:)
        execute(request_id, release_id, "cancel") do |state, request, _manifest, _path, _trust|
          journal.transition!(state, request, "AVAILABLE") if request["state"] == "IDLE"
          state["requests"].values.select { |row| row["release_id"] == release_id }.each do |row|
            journal.transition!(state, row, "CANCELLED") unless row["state"] == "CANCELLED"
            row["challenge"] = nil
          end
        end
      end
      def status
        journal.transaction do |state|
          { "installed" => { "version" => Product::VERSION, "authority" => "running_code_only" },
            "active_switch_supported" => false, "backup_ready" => false, "utc_qualified" => false,
            "requests" => state["requests"].values.map { |r| r.slice("id", "release_id", "version", "state", "error", "revision") },
            "history" => state["events"] }
        end
      end
      def verified_package?(path, manifest)
        data = Filesystem.read(path, maximum: Manifest::MAX_PACKAGE)
        raise Invalid, "package_digest" unless data.bytesize == manifest["package"]["bytes"] && Digest::SHA256.hexdigest(data) == manifest["package"]["sha256"]
        true
      end
      def authorize_time!(state, manifest, release_id, challenge, receipt, trust)
        utc = @time.verify!(challenge, receipt, trust, state)
        if utc >= manifest["expires_at"]
          state["expired"] |= [ release_id ]
          raise Invalid, "expiry_record_capacity" if state["expired"].length > 256
          journal.persist(state)
          raise Invalid, "manifest_expired"
        end
        raise Invalid, "manifest_prepublication" if utc < manifest["published_at"]
        raise Invalid, "manifest_expired" if state["expired"].include?(release_id)
      end
      def notify_progress(state, request)
        return unless @progress && request["id"] == @current_id
        @progress.call(attest(state, request, @operation))
      rescue StandardError
        raise Invalid, "progress_delivery_failed"
      end
      def attest(state, request, operation)
        begin
          trust = authority
          trust.apply!(state)
          roots = trust.roots
        rescue Invalid
          raise unless request["error"]
          # A failed trust-policy observation cannot authorize a release, but a
          # last-accepted nonrevoked status key may attest the durable failure.
          roots = state["accepted_roots"] || {}
        end
        key_id = Releases.key_id(@signer)
        raise Invalid, "status_key_untrusted" unless roots.dig(key_id, "purpose") == "status" && !state["revoked"].include?(key_id)
        request["revision"] += 1
        journal.persist(state)
        statement = { "format" => "railpress.operator.v1", "request_id" => request["id"], "release_id" => request["release_id"],
          "operation" => operation, "state" => request["state"], "revision" => request["revision"],
          "version" => request["version"], "publisher" => request["publisher"], "error" => request["error"],
          "installed_version" => Product::VERSION, "activation_supported" => false, "backup_ready" => false,
          "metadata" => request["metadata"] || {},
          "history" => state["events"].select { |event| event["request"] == request["id"] }.last(32) }
        { "statement" => statement, "signature" => { "algorithm" => "ed25519", "key_id" => key_id,
          "signature" => Base64.strict_encode64(@signer.sign(nil, Releases.canonical(statement))) } }
      end
      def execute(id, release_id, operation, &block)
        native = File.join(journal.root, "host.json")
        return execute_unlocked(id, release_id, operation, &block) unless File.exist?(native) || File.symlink?(native)
        config = Releases.parse(Filesystem.read(native, maximum: 65_536), limit: 65_536)
        raise Invalid, "unqualified_host_profile" unless config["format"] == "railpress.native-host.v1" && config["scope"] == "isolated-synthetic-nginx-v1"
        path = File.join(journal.root, "operation.lock")
        Filesystem.read(path, maximum: 0) if File.exist?(path) || File.symlink?(path)
        File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          raise Invalid, "operation_busy" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          execute_unlocked(id, release_id, operation, &block)
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
      def execute_unlocked(id, release_id, operation)
        raise Invalid, "request_id" unless UUID.match?(id.to_s)
        Releases.identity!(release_id)
        journal.transaction do |state|
          @current_id, @operation = id, operation
          request = state["requests"][id]
          if request
            raise Invalid, "request_conflict" unless request["release_id"] == release_id
          else
            raise Invalid, "request_capacity" if state["requests"].length >= 64
            request = { "id" => id, "release_id" => release_id, "state" => "IDLE", "revision" => 0 }
            state["requests"][id] = request
          end
          begin
            trust = authority
            trust.apply!(state)
            journal.persist(state)
            request["error"] = nil
            if operation == "cancel"
              manifest = nil
              yield state, request, nil, nil, trust
            else
              manifest, signature, path = metadata(release_id)
              publisher = trust.verify!(Releases.canonical(manifest), signature, state, purpose: "release")
              request["version"] = manifest["version"]
              request["publisher"] = publisher
              request["metadata"] = manifest.slice("version", "channel", "published_at", "expires_at", "sequence", "changelog", "compatibility", "provenance")
              yield state, request, manifest, path, trust
            end
          rescue Invalid, SecurityClock::Unavailable, SystemCallError, IOError => error
            request["error"] = error.is_a?(Invalid) ? error.message : "operator_io_unavailable"
            request["error"] = "operator_failed" unless request["error"].match?(/\A[a-z_]{1,80}\z/)
            if request["state"] == "IDLE"
              journal.transition!(state, request, "AVAILABLE")
            end
            journal.transition!(state, request, "FAILED_STAGED", detail: request["error"]) if %w[AVAILABLE PREFLIGHT DOWNLOADING VERIFIED STAGED].include?(request["state"])
          end
          attest(state, request, operation)
        ensure
          @current_id = nil
          @operation = nil
        end
      end
    end
  end
end
