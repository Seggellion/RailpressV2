# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :user_session
  def user
    user_session&.user
  end
end
