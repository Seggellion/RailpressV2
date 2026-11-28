# frozen_string_literal: true

module Railpress
  module Extensions
    class Trust
      PACKAGE = "extension-package.v1"
      RECEIPT = "extension-receipt.v1"
      LIMIT = 64 * 1024

      def initialize(bytes)
        document = Releases.parse(bytes, limit: LIMIT)
        Releases.keys!(document, %w[format keys revoked])
        raise Invalid, "extension_trust_format" unless document["format"] == "railpress.extension-trust.v1"
        @roots = document["keys"]
        @revoked = document["revoked"]
        raise Invalid, "extension_trust_roots" unless @roots.is_a?(Hash) && @roots.length.between?(1, 64) &&
          @revoked.is_a?(Array) && @revoked.length <= 256 && @revoked == @revoked.uniq
        @revoked.each { |key| Releases.identity!(key) }
        @roots.each do |key, record|
          Releases.identity!(key)
          Releases.keys!(record, %w[public_key purpose scopes minimum_sequence])
          raise Invalid, "extension_trust_key" unless Releases.key_id(Releases.public_key(record["public_key"])) == key
          raise Invalid, "extension_trust_purpose" unless [ PACKAGE, RECEIPT, Catalog::FORMAT ].include?(record["purpose"])
          scopes = record["scopes"]
          raise Invalid, "extension_trust_scopes" unless scopes.is_a?(Array) && scopes.length.between?(1, 32) && scopes == scopes.uniq
          scopes.each { |scope| Extensions.id!(scope) }
          Extensions.generation!(record["minimum_sequence"], minimum: 1)
        end
        Extensions.freeze_tree(document)
        freeze
      end

      def verify!(bytes, purpose:, now: Time.now.to_i)
        envelope = Releases.parse(bytes, limit: LIMIT)
        Releases.keys!(envelope, %w[statement signature])
        statement = envelope["statement"]
        raise Invalid, "extension_statement" unless statement.is_a?(Hash) && statement["format"] == purpose
        key = Releases.signature!(Releases.canonical(statement), envelope["signature"], @roots, purpose: purpose)
        raise Invalid, "extension_key_revoked" if @revoked.include?(key)
        record = @roots.fetch(key)
        raise Invalid, "extension_signature_scope" unless record["scopes"].include?(Extensions.id!(statement["id"]))
        Extensions.generation!(statement["sequence"], minimum: record["minimum_sequence"])
        Extensions.generation!(statement["expires_at"], minimum: 1)
        raise Invalid, "extension_signature_expired" unless statement["expires_at"] > now
        Extensions.freeze_tree(statement)
      end
    end
  end
end
