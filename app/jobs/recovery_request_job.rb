# frozen_string_literal: true

class RecoveryRequestJob < ApplicationJob
  self.log_arguments = false
  queue_as :default
  def perform(field, digest)
    Identity::PasswordRecovery.deliver!(field, digest)
  end
end
