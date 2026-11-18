class MemberChallenge < ApplicationRecord
  include SecurityDeadline
  LIFETIME = 15.minutes
  belongs_to :site
  belongs_to :member, optional: true
  belongs_to :member_session, optional: true
end
