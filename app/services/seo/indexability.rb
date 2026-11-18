# frozen_string_literal: true

# Adapted from UltimaCraft a6e17605689442a91e697eae0584a0c2bf84f4bf; MIT (c) 2024-2026 Dustin Hill.
# See THIRD_PARTY_NOTICES.md. Fail-closed Railpress robots semantics.

module Seo
  class Indexability
    STATES = %i[index noindex conditional excluded unresolved].freeze
    NON_INDEXED_STATES = (STATES - [ :index ]).freeze

    attr_reader :state, :reason

    def self.index(reason: nil)
      new(state: :index, reason: reason)
    end

    def self.noindex(reason: nil)
      new(state: :noindex, reason: reason)
    end

    def self.conditional(reason: nil)
      new(state: :conditional, reason: reason)
    end

    def self.excluded(reason: nil)
      new(state: :excluded, reason: reason)
    end

    def self.unresolved(reason: nil)
      new(state: :unresolved, reason: reason)
    end

    def initialize(state:, reason: nil)
      normalized_state = state.to_sym
      raise ArgumentError, "unknown SEO indexability state: #{state.inspect}" unless normalized_state.in?(STATES)

      @state = normalized_state
      @reason = reason.presence
      freeze
    end

    def indexable?
      state == :index
    end

    def sitemap_eligible?
      indexable?
    end

    def robots
      indexable? ? "index, follow" : "noindex, nofollow"
    end
  end
end
