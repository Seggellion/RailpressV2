class MemberOauthAttempt < ApplicationRecord
  include SecurityDeadline
  LIFETIME = 5.minutes
  belongs_to :site
  belongs_to :member_session, optional: true
end
