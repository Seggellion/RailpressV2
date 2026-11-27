# frozen_string_literal: true

module Railpress
  module Recovery
    module Revocations
      FORMAT = "railpress.disk-revocations.v1"
      CANDIDATE_FORMAT = "railpress.disk-revocations.v2"
      PURPOSE = "disk-revocation"
      FIELDS = %w[format site from through issued_at expires_at events].freeze
      Ledger = Data.define(:modules, :candidates)
      module_function

      def verify!(bytes, key:, site:, checkpoint:, observed_head:, now:)
        verify_restore!(bytes, key: key, site: site, checkpoint: checkpoint, observed_head: observed_head,
          now: now, snapshot: nil, packages: nil, package_ids: [], candidate_modules: []).modules
      end

      def verify_restore!(bytes, key:, site:, checkpoint:, observed_head:, now:, snapshot:, packages:, package_ids:, candidate_modules:)
        Releases.integer!(checkpoint, 0, 2**53 - 1)
        Releases.integer!(observed_head, checkpoint, 2**53 - 1)
        envelope = Releases.parse(bytes, limit: 65_536)
        Releases.keys!(envelope, %w[statement signature])
        data = envelope["statement"]
        raise Error, "revocation_coverage" unless data.is_a?(Hash)
        candidate_format = data["format"] == CANDIDATE_FORMAT
        Releases.keys!(data, candidate_format ? FIELDS + %w[snapshot packages] : FIELDS)
        signer = Releases.key_id(key)
        Releases.signature!(Releases.canonical(data), envelope["signature"],
          { signer => { "public_key" => key.public_to_pem, "purpose" => PURPOSE } }, purpose: PURPOSE)
        unless [ site, checkpoint, observed_head ].eql?(data.values_at("site", "from", "through"))
          raise Error, "revocation_coverage"
        end
        if candidate_format
          NativeHost.uuid!(snapshot)
          Releases.identity!(packages)
          raise Error, "revocation_snapshot_binding" unless data.values_at("snapshot", "packages") == [ snapshot, packages ]
        elsif data["format"] != FORMAT || candidate_modules.any?
          raise Error, "revocation_coverage"
        end
        issued, expiry = data.values_at("issued_at", "expires_at")
        Releases.integer!(issued, now - 300, now)
        Releases.integer!(expiry, now + 1, issued + 300)
        events = data.fetch("events")
        raise Error, "revocation_coverage" unless events.is_a?(Array) && events.size <= 256 && events.size == observed_head - checkpoint

        modules, candidates = [], []
        events.each_with_index do |event, index|
          raise Error, "revocation_event" unless event.is_a?(Hash) && (checkpoint + index + 1).eql?(event["sequence"])
          id = Extensions.id!(event["module_id"])
          case event["kind"]
          when "module_withdrawn"
            Releases.keys!(event, %w[sequence kind module_id])
            raise Error, "revocation_event" if candidate_format && !package_ids.include?(id)
            modules << id
          when "candidate_withdrawn"
            Releases.keys!(event, %w[sequence kind module_id subject_id])
            raise Error, "revocation_event" unless candidate_format && candidate_modules.include?(id)
            candidates << [ id, Extensions.uuid!(event["subject_id"]) ]
          else
            raise Error, "revocation_event"
          end
        end
        Ledger.new(modules: modules.uniq.freeze, candidates: Extensions.freeze_tree(candidates.uniq))
      end

      def reconcile!(database, withdrawn:, site: nil, candidates: [])
        database.connection do |client, engine|
          run = ->(sql) { engine == "postgresql" ? client.exec(sql) : client.query(sql) }
          run.call("BEGIN")
          begin
            if withdrawn.nil?
              run.call("UPDATE extension_installations SET enabled=FALSE, activation_generation=activation_generation+1 WHERE enabled=TRUE")
            else
              withdrawn.each do |id|
                Extensions.id!(id)
                run.call("UPDATE extension_installations SET enabled=FALSE, activation_generation=activation_generation+1 WHERE enabled=TRUE AND module_id='#{id}'")
              end
              candidates.each { |id, subject| Extensions::CandidateWithdrawals.insert!(client, engine, site, id, subject) }
            end
            run.call("COMMIT")
          rescue StandardError
            run.call("ROLLBACK")
            raise
          end
        end
      end
    end
  end
end
