# frozen_string_literal: true

require "uri"

class User < ApplicationRecord
  ROLES = %w[owner administrator editor author].freeze
  has_secure_password reset_token: false
  enum :role, ROLES.index_with(&:itself), validate: true
  has_many :media_assets, foreign_key: :author_id, dependent: :restrict_with_error
  has_many :media_uploads, foreign_key: :author_id, dependent: :restrict_with_error
  has_many :seo_diagnostic_runs, class_name: "Seo::DiagnosticRun", foreign_key: :requester_id, dependent: :restrict_with_error
  has_many :contents, foreign_key: :author_id, dependent: :restrict_with_error
  has_many :editorial_previews, class_name: "ContentPreview", foreign_key: :actor_id, dependent: :destroy
  has_many :editorial_revisions, class_name: "ContentRevision", foreign_key: :actor_id, dependent: :restrict_with_error
  has_many :navigation_previews, foreign_key: :actor_id, dependent: :delete_all
  has_many :user_sessions, dependent: :delete_all
  has_many :password_resets, dependent: :delete_all
  before_validation :normalize_identity
  before_update :require_managed_role_change
  before_destroy :require_managed_removal
  validates :username, presence: true, format: { with: /\A[a-z0-9][a-z0-9._-]{2,39}\z/ }
  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, if: -> { password.present? }
  validates :password_confirmation, presence: true, if: -> { password.present? }

  def with_managed_identity_change
    @managed_identity_change = true
    yield
  ensure
    @managed_identity_change = false
  end

  private
  def normalize_identity
    self.username = Railpress::IdentityKey.normalize(username)
    self.email = Railpress::IdentityKey.normalize(email)
    self.username_key = Railpress::IdentityKey.digest(username)
    self.email_key = Railpress::IdentityKey.digest(email)
  rescue ArgumentError
    errors.add(:base, "Identity must be valid UTF-8")
    throw :abort
  end

  def require_managed_role_change
    return unless will_save_change_to_role? && !@managed_identity_change
    errors.add(:role, "must be changed through owner administration")
    throw :abort
  end

  def require_managed_removal
    return if @managed_identity_change
    errors.add(:base, "Account removal requires owner administration")
    throw :abort
  end
end
