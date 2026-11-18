# frozen_string_literal: true

class PasswordReset < ApplicationRecord
  include SecurityDeadline
  belongs_to :user
  LIFETIME = 15.minutes
end
