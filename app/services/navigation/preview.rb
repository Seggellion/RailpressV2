module Navigation
  module Preview
    module_function

    def issue(actor:, menu:, authentication_token:)
      NavigationPreview.transaction do
        actor.lock!
        Identity::Capabilities.require!(actor, :manage_menus)
        menu.lock!
        raise Mutation::Invalid, "Choose a draft location and an active trusted theme before preview." unless menu.status == "active" && MenuLocation.where(draft_menu_id: menu.id).exists? && ThemeState.find_by(site_id: menu.site_id)&.active_installation_id
        raise Identity::Capabilities::Denied unless UserSession.resolve(authentication_token)&.user_id == actor.id
        digest = Digest::SHA256.hexdigest(authentication_token)
        NavigationPreview.where(actor: actor, session_digest: digest).delete_all
        token = SecureRandom.hex(32)
        NavigationPreview.create!(menu: menu, actor: actor, auth_version: actor.auth_version, menu_version: menu.lock_version,
          session_digest: digest, token_digest: Digest::SHA256.hexdigest(token), expires_at: NavigationPreview::LIFETIME.from_now)
        { "token" => token }
      end
    end

    def resolve(actor:, authentication_token:, credential:)
      return unless actor && authentication_token.is_a?(String) && credential.is_a?(Hash)
      token = credential["token"]
      return unless token.is_a?(String) && token.match?(/\A[0-9a-f]{64}\z/)
      return unless UserSession.resolve(authentication_token)&.user_id == actor.id
      NavigationPreview.transaction do
        actor.lock!
        next unless Identity::Capabilities.allowed?(actor, :manage_menus)
        record = NavigationPreview.lock.find_by(token_digest: Digest::SHA256.hexdigest(token), actor: actor,
          session_digest: Digest::SHA256.hexdigest(authentication_token), auth_version: actor.auth_version)
        next unless record && record.deadline_valid_locked?
        Menu.find_by(id: record.menu_id, site_id: Site.find_by!(singleton_key: 1).id, status: "active", lock_version: record.menu_version)
      end
    end

    def revoke(actor:, authentication_token:, credential:)
      return unless actor && authentication_token.is_a?(String) && credential.is_a?(Hash)
      token = credential["token"]
      return unless token.is_a?(String) && token.match?(/\A[0-9a-f]{64}\z/)
      NavigationPreview.where(actor: actor, token_digest: Digest::SHA256.hexdigest(token),
        session_digest: Digest::SHA256.hexdigest(authentication_token)).delete_all
    end
  end
end
