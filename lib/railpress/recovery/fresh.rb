# frozen_string_literal: true

module Railpress
  module Recovery
    class Fresh
      MEMBER_EPHEMERAL = %w[member_oauth_attempts member_challenges member_sessions].freeze
      attr_reader :receipt
      def self.authority_unchanged!(current, point)
        %w[users members member_identities].each do |table|
          raise Error, "credential_authority_changed" unless current.fetch("before").fetch(table) == point.fetch("before").fetch(table)
        end
        true
      end
      def initialize(source:, target:, manifest:, dump:, validator:, clock_root:, app_root:, configuration_files:, theme_root:)
        @source, @target, @manifest, @dump, @validator, @clock_root = source, target, manifest, dump, validator, clock_root
        @app_root, @configuration_files, @theme_root = app_root, configuration_files, theme_root
        @receipt = { "format" => "railpress.fresh-recovery.v1", "state" => "PREFLIGHT", "id" => SecureRandom.uuid,
          "manifest_id" => manifest.fetch("id"), "phases" => [], "promotion" => "UNAVAILABLE", "workers" => "STOPPED" }
      end
      def phase(name)
        receipt["phases"] << { "phase" => name, "monotonic" => Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        F.atomic(@target.path("run", "fresh-recovery.json"), Releases.canonical(receipt))
      end
      def run!
        # One-shot target. No resume/retry over partial DDL; failure stays private.
        lock = @target.lock!
        raise Error, "fresh_operation_exists" if File.exist?(@target.path("run", "fresh-recovery.json"))
        owned = true
        source_db = @source.database
        target_db = @target.database
        source_identity = @source.database!.last
        target_identity = @target.database!.last
        raise Error, "fresh_source_binding" unless source_identity == @manifest["database"]["source"]
        raise Error, "fresh_same_target" if source_identity["database"] == target_identity["database"] || source_identity["username"] == target_identity["username"]
        raise Error, "fresh_engine" unless @source.data["engine"] == @target.data["engine"] && @target.data["engine"] == @manifest["database"]["engine"]
        raise Error, "fresh_installation" unless [ @source.data["install_id"], @target.data["install_id"] ] == [ @manifest["site"]["install_id"] ] * 2
        source_db.assert_installation!
        source_db.assert_restore_offline!
        original = source_db.integrity.capture
        # Restoring older role/account/link authority must not resurrect a
        # privilege or closed/unlinked identity. Conservatively refuse changes.
        self.class.authority_unchanged!(original, @manifest["database"]["integrity"])
        raise Error, "password_verifiers_changed" unless Recovery.digest(source_db.query("SELECT id,password_digest FROM users ORDER BY id")) == @manifest["security"]["password_verifiers_sha256"]
        @target.empty!
        raise Error, "fresh_clock_root" unless File.absolute_path(@clock_root) == @clock_root && @clock_root == @target.path("candidate-private") && !File.exist?(@clock_root) && !File.symlink?(@clock_root)
        F.capacity!(@target.root, 8 * 1024**3 + File.size(@dump) * 3)
        initial = @validator.run
        required = initial["checks"].except("restored_database")
        raise Error, "backup_dependencies_unverified" unless required.values.all? { |value| value == "VERIFIED" }
        receipt["source"] = source_identity
        receipt["target"] = target_identity
        phase("PREFLIGHT_VERIFIED")
        @target.empty!
        phase("NATIVE_LOAD")
        target_db.restore_fresh!(receipt["id"], @dump, expected_tables: @manifest["database"]["integrity"]["schema"]["tables"],
          progress: ->(name) { phase(name) })
        phase("VERIFY_RECORDS")
        before = @validator.run(database: target_db)
        receipt["post_load_validation"] = before
        raise Error, "restored_dependencies_unverified" unless before["status"] == "VERIFIED"
        phase("REVOKE_CREDENTIALS")
        @member_records_after = target_db.connection do |client, engine|
          rows = (engine == "postgresql" ? client.exec("SELECT * FROM members") : client.query("SELECT * FROM members", cast: false)).to_a
          target_db.integrity.records(rows.map { |row| row.merge("auth_version" => row.fetch("auth_version").to_i + 1) })
        end
        target_db.revoke_restored_credentials!
        # Member credentials are also epoch-bound; remove them explicitly and
        # increment Member auth versions. Preserve identity/verification policy.
        MEMBER_EPHEMERAL.each { |table| target_db.execute("DELETE FROM #{target_db.quote_identifier(table)}") }
        target_db.execute("UPDATE members SET auth_version=auth_version+1")
        expected = JSON.parse(JSON.generate(@manifest["database"]["integrity"]))
        MEMBER_EPHEMERAL.each { |table| expected["after_revocation"][table] = { "count" => 0, "sha256" => Recovery.digest([]) } }
        expected["after_revocation"]["members"] = member_records_after
        target_db.integrity.verify!(expected, revoked: true)
        Dir.mkdir(@clock_root, 0o700)
        F.atomic(File.join(@clock_root, "setup.json"), Releases.canonical({ "version" => 1, "status" => "installed", "install_id" => @manifest["site"]["install_id"] }))
        clock = SecurityClock.new(@clock_root).sample
        fingerprint = Digest::SHA256.hexdigest(clock["domain"] + clock["epoch"])
        raise Error, "fresh_clock_not_rotated" unless clock["anomaly"] && fingerprint != @manifest["consistency"]["clock_binding_sha256"]
        phase("VERIFY_SECURITY_AND_ORIGINAL")
        source_db.assert_restore_offline!
        source_db.integrity.verify!(original)
        phase("PRODUCTION_RAILS_PROBE")
        candidate = Candidate.check!(target: @target, app_root: @app_root, clock_root: @clock_root, configuration_files: @configuration_files, theme_root: @theme_root)
        target_db.integrity.verify!(expected, revoked: true)
        source_db.integrity.verify!(original)
        @target.database.assert_restore_offline!
        receipt.merge!("state" => "VERIFIED", "database_integrity" => true, "media" => before["checks"].select { |key, _| key.start_with?("media_") },
          "original_unchanged" => true, "clock_rotated" => true, "scheduling_held" => true, "ephemeral_revoked" => true,
          "application_rack" => candidate, "application_http" => "NOT TESTED", "candidate_clock_fingerprint" => fingerprint,
          "cutover" => "NOT AUTHORIZED", "queue_replay" => "PROHIBITED pending operator reconciliation")
        phase("VERIFIED")
        receipt
      rescue StandardError => error
        if owned
          receipt["state"] = "FAILED/QUARANTINED"
          receipt["error"] = error.is_a?(Error) && error.message.match?(/\A[a-z_]{1,100}\z/) ? error.message : "fresh_recovery_failed"
          begin
            receipt["original_unchanged"] = source_db && original && source_db.integrity.verify!(original)
          rescue StandardError
            receipt["original_unchanged"] = "UNKNOWN"
          end
          phase("QUARANTINED")
        end
        raise
      ensure
        lock&.close
      end
      def member_records_after
        # Source may have newer member writes: use pre-revocation restored rows,
        # captured immediately before the permitted transform.
        @member_records_after || raise(Error, "member_recovery_evidence_missing")
      end
    end
  end
end
