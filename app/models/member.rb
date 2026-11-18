class Member < ApplicationRecord
  belongs_to :site
  has_many :member_identities, dependent: :destroy
  has_many :member_sessions, dependent: :destroy
  validates :public_id, format: { with: /\A[0-9a-f-]{36}\z/ }
  validates :status, inclusion: { in: %w[active closed] }
  validates :email, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
  def active? = status == "active"
end
