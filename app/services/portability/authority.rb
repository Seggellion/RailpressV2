module Portability
  module Authority
    class Expired < StandardError; end
    module_function
    # All asynchronous authority is bound to an existing authenticated session.
    # Tokens and SecurityClock bindings never enter archives or job arguments.
    def locked(actor:, session_id:, auth_version: nil)
      Site.transaction do
        site = Site.find_by!(singleton_key: 1); site.lock!
        user = User.lock.find_by(id: actor&.id)
        raise Identity::Capabilities::Denied unless user
        Identity::Capabilities.require!(user, :manage_identity)
        session = UserSession.lock.find_by(id: session_id, user_id: user.id)
        unless session && session.auth_version == user.auth_version && (auth_version.nil? || auth_version == user.auth_version) && session.deadline_valid_locked?
          raise Expired, "Approval expired or credentials changed. Sign in and explicitly approve again."
        end
        yield site, user, session
      end
    end
    def record_locked(record, &block)
      locked(actor: record.actor, session_id: record.approval_session_id, auth_version: record.auth_version) do |site, user, session|
        record.lock!
        raise Identity::Capabilities::Denied unless record.site_id == site.id && record.actor_id == user.id
        block.call(site, user, session)
      end
    end
    def version!(record, version)
      raise Editorial::Workflow::Conflict, "This portability review changed. Reload and compare before approving." unless version.to_s == record.lock_version.to_s
    end
  end
end
