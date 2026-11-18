# frozen_string_literal: true

class RecoveryMailer < ApplicationMailer
  self.logger = nil
  layout false

  def instructions(user, token)
    @token = token
    mail(to: user.email, from: "recovery@railpress.invalid", subject: "Railpress account recovery")
  end
end
