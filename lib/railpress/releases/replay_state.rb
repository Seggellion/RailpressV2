# frozen_string_literal: true

module Railpress
  module Releases
    # Shared anti-rollback evidence across staging and native host journals.
    # Neither journal may forget an expiry/revocation seen by the other.
    module ReplayState
      module_function
      def merge!(target, source)
        raise Invalid, "replay_state_corrupt" unless source.is_a?(Hash) &&
          source["trust_generation"].is_a?(Integer) && source["trust_generation"] >= 0 &&
          source["utc_max"].is_a?(Numeric) && source["utc_max"].finite? && source["utc_max"] >= 0
        %w[revoked expired].each do |field|
          raise Invalid, "replay_state_corrupt" unless source[field].is_a?(Array) && source[field].length <= 256
          source[field].each { |id| Releases.identity!(id) }
          target[field] |= source[field]
          raise Invalid, "replay_state_capacity" if target[field].length > 256
        end
        if source["trust_generation"] > target["trust_generation"]
          Releases.identity!(source["trust_digest"])
          raise Invalid, "replay_state_corrupt" unless source["accepted_roots"].is_a?(Hash) && source["accepted_roots"].length <= 64
          %w[trust_generation trust_digest accepted_roots].each { |key| target[key] = source[key] }
        elsif source["trust_generation"].positive? && source["trust_generation"] == target["trust_generation"]
          raise Invalid, "replay_trust_conflict" unless source["trust_digest"] == target["trust_digest"]
        end
        source_sequence = source.fetch("sequence", {})
        raise Invalid, "replay_state_corrupt" unless source_sequence.is_a?(Hash) && source_sequence.length <= 4
        target["sequence"] ||= {}
        source_sequence.each do |channel, reservation|
          raise Invalid, "replay_state_corrupt" unless channel == "development"
          Releases.keys!(reservation, %w[sequence release_id request_id])
          Releases.integer!(reservation["sequence"], 1, 2**53 - 1)
          Releases.identity!(reservation["release_id"])
          raise Invalid, "replay_state_corrupt" unless Releases::UUID.match?(reservation["request_id"].to_s)
          current = target["sequence"][channel]
          if !current || reservation["sequence"] > current["sequence"]
            target["sequence"][channel] = reservation
          elsif reservation["sequence"] == current["sequence"]
            raise Invalid, "replay_sequence_conflict" unless current == reservation
          end
        end
        if source["utc_max_ns"]
          raise Invalid, "replay_state_corrupt" unless source["utc_max_ns"].is_a?(String) && source["utc_max_ns"].match?(/\A[1-9]\d{17,23}\z/)
          target["utc_max_ns"] = [ Integer(target.fetch("utc_max_ns", "0")), Integer(source["utc_max_ns"]) ].max.to_s
        end
        target["utc_max"] = [ target["utc_max"], source["utc_max"] ].max
        target
      end
    end
  end
end
