class MemberIdentity < ApplicationRecord
  belongs_to :member
  validates :provider, inclusion: { in: [ "discord" ] }
  validates :subject, format: { with: /\A[1-9][0-9]{5,24}\z/ }
end
