# frozen_string_literal: true

module Railpress
  module Releases
    class Authority
      attr_reader :roots, :generation, :revoked
      def initialize(document)
        Releases.keys!(document, %w[format generation keys revoked])
        raise Invalid, "trust_format" unless document["format"] == "railpress.trust.v1"
        Releases.integer!(document["generation"], 1, 2**53 - 1)
        @generation = document["generation"]
        @roots = document["keys"]
        @revoked = document["revoked"]
        raise Invalid, "trust_roots" unless roots.is_a?(Hash) && roots.length.between?(1, 64) && revoked.is_a?(Array) && revoked.length <= 256
        revoked.each { |id| Releases.identity!(id) }
        roots.each do |id, row|
          Releases.identity!(id)
          Releases.keys!(row, %w[purpose public_key])
          raise Invalid, "key_purpose" unless %w[release time status].include?(row["purpose"])
          Releases.text!(row["public_key"], 512)
          raise Invalid, "key_identity" unless Releases.key_id(Releases.public_key(row["public_key"])) == id
        end
      end
      def apply!(state)
        raise Invalid, "trust_rollback" if generation < state.fetch("trust_generation")
        identity = Digest::SHA256.hexdigest(Releases.canonical({ "keys" => roots, "revoked" => revoked }))
        raise Invalid, "trust_generation_reused" if generation == state["trust_generation"] && state["trust_digest"] != identity
        state["trust_generation"] = generation
        state["trust_digest"] = identity
        state["accepted_roots"] = roots
        state["revoked"] |= revoked
        raise Invalid, "revocation_capacity" if state["revoked"].length > 256
      end
      def verify!(bytes, signature, state, purpose:)
        id = Releases.signature!(bytes, signature, roots, purpose: purpose)
        raise Invalid, "revoked_publisher" if state.fetch("revoked").include?(id) || revoked.include?(id)
        id
      end
    end
    class ReleaseTime
      def initialize(clock)
        @clock = clock
      end
      def challenge
        sample = @clock.sample
        raise Invalid, "clock_anomaly" if sample["anomaly"]
        { "nonce" => SecureRandom.hex(32), "domain" => sample.fetch("domain"), "epoch" => sample.fetch("epoch"),
          "elapsed" => sample.fetch("elapsed") }
      rescue SecurityClock::Unavailable
        raise Invalid, "security_time_unavailable"
      end
      def verify!(challenge, receipt, authority, state)
        Releases.keys!(receipt, %w[statement signature])
        statement = receipt.fetch("statement")
        precise = statement["format"] == "railpress.utc.v2"
        Releases.keys!(statement, precise ? %w[format nonce domain epoch elapsed utc_ns] : %w[format nonce domain epoch elapsed utc])
        valid_time = precise ? statement["utc_ns"].is_a?(String) && statement["utc_ns"].match?(/\A[1-9]\d{17,23}\z/) :
          statement["format"] == "railpress.utc.v1" && statement["utc"].is_a?(Integer) && statement["utc"].positive?
        raise Invalid, "time_receipt" unless valid_time && challenge.all? { |k, v| statement[k] == v }
        authority.verify!(Releases.canonical(statement), receipt["signature"], state, purpose: "time")
        now = @clock.sample
        raise Invalid, "clock_anomaly" if now["anomaly"]
        delta = now.fetch("elapsed") - challenge.fetch("elapsed")
        raise Invalid, "time_receipt_stale" unless now["domain"] == challenge["domain"] && now["epoch"] == challenge["epoch"] && delta.between?(0, 60)
        if precise
          elapsed_ns = ((now.fetch("elapsed").to_s.to_r - challenge.fetch("elapsed").to_s.to_r) * 1_000_000_000).floor
          observed_ns = Integer(statement["utc_ns"]) + elapsed_ns
          prior_ns = state["utc_max_ns"] ? Integer(state["utc_max_ns"]) : (state.fetch("utc_max").to_s.to_r * 1_000_000_000).floor
          raise Invalid, "trusted_utc_rollback" if observed_ns < prior_ns
          state["utc_max_ns"] = observed_ns.to_s
          state["utc_max"] = [ state.fetch("utc_max"), observed_ns.fdiv(1_000_000_000) ].max
          Rational(observed_ns, 1_000_000_000)
        else
          utc = statement["utc"] + delta
          raise Invalid, "trusted_utc_rollback" if utc < state.fetch("utc_max") ||
            (state["utc_max_ns"] && utc.to_s.to_r * 1_000_000_000 < Integer(state["utc_max_ns"]))
          state["utc_max"] = utc
          utc
        end
      rescue SecurityClock::Unavailable, KeyError, TypeError
        raise Invalid, "security_time_unavailable"
      end
    end
  end
end
