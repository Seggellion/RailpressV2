# frozen_string_literal: true

module Identity
  class ManageUsers
    class LastOwner < StandardError; end
    def self.create!(actor:, attributes:)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor.lock!
        Capabilities.require!(actor, :manage_users)
        user = User.create!(attributes.slice(:username, :email, :password, :password_confirmation, :role))
        Activity::Recorder.record!(actor: actor, action: "identity.user_created", subject: user, details: { to_role: user.role })
        user
      end
    end

    def self.change_role!(actor:, user:, role:)
      mutate!(actor: actor, user: user, removing: false, role: role)
    end

    def self.remove!(actor:, user:)
      mutate!(actor: actor, user: user, removing: true)
    end

    def self.mutate!(actor:, user:, removing:, role: nil)
      Site.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        actor.lock!
        Capabilities.require!(actor, :manage_users)
        user.lock!
        owner_leaving = user.owner? && (removing || role != "owner")
        if owner_leaving
          replacement = User.where(role: "owner").where.not(id: user.id).order(:id).lock.first
          raise LastOwner, "The last owner cannot be removed or demoted" unless replacement
          site.update!(owner: replacement) if site.owner_id == user.id
        end
        previous_role = user.role
        user.with_managed_identity_change do
          user.user_sessions.delete_all
          user.password_resets.update_all(used_at: Time.current)
          removing ? user.destroy! : user.update!(role: role, auth_version: user.auth_version + 1)
        end
        Activity::Recorder.record!(actor: actor, action: removing ? "identity.user_removed" : "identity.role_changed", subject: user, details: { from_role: previous_role, to_role: removing ? nil : user.role })
      end
    end
    private_class_method :mutate!
  end
end
