# frozen_string_literal: true

module Railpress
  module Extensions
    module CandidateWithdrawals
      PREFIX = "extension_candidate_withdrawal:"
      module_function

      def supports?(manifest)
        manifest.data.fetch("provides").include?("#{manifest.id}.candidate_withdrawal")
      end

      def scope(site, module_id)
        "#{PREFIX}#{Extensions.uuid!(site)}:#{Extensions.id!(module_id)}"
      end

      def subjects(site, module_id)
        name = scope(site, module_id)
        ::PlatformState.where(scope_digest: Digest::SHA256.hexdigest(name), scope_name: name).select(:key_name)
      end

      def withdrawn?(site, module_id, subject)
        subjects(site, module_id).exists?(key_name: Extensions.uuid!(subject))
      end

      def insert!(client, engine, site, module_id, subject)
        name = scope(site, module_id)
        key = Extensions.uuid!(subject)
        values = [ name, key, Digest::SHA256.hexdigest(name), Digest::SHA256.hexdigest(key), "{}" ]
        columns = "scope_name, key_name, scope_digest, key_digest, payload, created_at, updated_at"
        if engine == "postgresql"
          client.exec_params("INSERT INTO platform_states (#{columns}) VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) " \
            "ON CONFLICT (scope_digest, key_digest) DO NOTHING", values)
        else
          statement = client.prepare("INSERT INTO platform_states (#{columns}) VALUES (?, ?, ?, ?, ?, UTC_TIMESTAMP(6), UTC_TIMESTAMP(6)) " \
            "ON DUPLICATE KEY UPDATE id = id")
          statement.execute(*values)
        end
      ensure
        statement&.close
      end
    end
  end
end
