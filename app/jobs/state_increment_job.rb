# frozen_string_literal: true

class StateIncrementJob < ApplicationJob
  queue_as :default

  def perform(id)
    PlatformState.transaction do
      state = PlatformState.lock.find(id)
      state.update!(payload: { "count" => state.payload.fetch("count") + 1 })
    end
  end
end
