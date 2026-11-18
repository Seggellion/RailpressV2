module Privacy
  module Policy
    module_function
    def configure!(actor:, revision:, value:)
      raise Identity::Capabilities::Denied unless actor.is_a?(User)
      raise Invalid unless %w[0 1].include?(value)
      version = actor.auth_version
      Site.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        actor.lock!
        raise Identity::Capabilities::Denied unless actor.auth_version == version
        Identity::Capabilities.require!(actor, :manage_identity)
        raise Conflict unless revision.to_s == site.privacy_revision.to_s
        site.update!(privacy_first_anonymous: value == "1", privacy_revision: site.privacy_revision + 1)
        Activity::Recorder.record!(actor: actor, action: "identity.site_updated", subject: site, details: { reason: "anonymous_privacy_policy" })
        site
      end
    end
  end
end
