module Themes
  module Selection
    Pair = Data.define(:installation, :overlay, :preview)
    module_function
    def preview(actor, authentication_token, credential)
      return unless actor&.owner? && credential
      Site.transaction do
        site = Site.lock.find_by(singleton_key: 1)
        next unless site
        actor.lock!
        state = ThemeState.find_by(site: site)
        record = bound_record(actor, authentication_token, credential, state)
        Pair.new(installation: record.theme_installation, overlay: record.theme_overlay, preview: true) if record
      end
    end
    def bound_record(actor, authentication_token, credential, state)
      return unless state
      return unless actor&.owner? && authentication_token.is_a?(String) && credential.is_a?(Hash)
      token = credential["token"] || credential[:token]
      return unless token.is_a?(String) && token.match?(/\A[0-9a-f]{64}\z/)
      return unless UserSession.resolve(authentication_token)&.user_id == actor.id
      record = ThemePreview.lock.find_by(token_digest: Digest::SHA256.hexdigest(token), actor_id: actor.id,
        session_digest: Digest::SHA256.hexdigest(authentication_token), auth_version: actor.auth_version,
        state_version: state.lock_version, engine_fingerprint: Railpress::Extensions.registry.fingerprint)
      return unless record && record.theme_installation.site_id == state.site_id &&
        record.theme_overlay.theme_installation_id == record.theme_installation_id && record.deadline_valid_locked?
      record
    end
    def active(site)
      state = ThemeState.find_by(site: site)
      return unless state&.active_installation_id
      Pair.new(installation: state.active_installation, overlay: state.active_overlay, preview: false)
    end
    def call(site:, actor:, authentication_token:, credential:)
      preview(actor, authentication_token, credential) || active(site)
    end
  end
end
