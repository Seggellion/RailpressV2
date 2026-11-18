module Membership
  module Discord
    ISSUER = "https://discord.com".freeze
    module_function
    def cipher
      key = Rails.application.key_generator.generate_key("railpress.member.pkce.v1", 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
    def settings_fingerprint(settings)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, JSON.generate(settings.sort.to_h))
    end
    def scopes(site, linking: false) = site.member_email_required || linking ? %w[identify email] : [ "identify" ]
    def start!(browser:, client:, member_session: nil, confirmation: false)
      Membership.locked do |site|
        raise Unavailable unless Policy.method_allowed?(site, "discord")
        raise Invalid unless browser.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(browser)
        MemberThrottle.consume!(scope: "oauth-ip", identity: client, limit: 15, window: 15.minutes)
        if member_session
          member_session.lock!
          member_session.member.lock!
          raise Invalid unless confirmation && member_session.member.active? && member_session.auth_version == member_session.member.auth_version && member_session.fresh_proof?
        end
        state = SecureRandom.hex(32)
        verifier = SecureRandom.urlsafe_base64(48, false)
        settings = Providers.current.discord_settings(origin: site.canonical_origin)
        Membership.prune!
        MemberOauthAttempt.create!(site: site, member_session: member_session, purpose: member_session ? "link" : "signin", browser_digest: Membership.digest(browser), state_digest: Membership.digest(state),
          callback: settings.fetch("callback"), provider_fingerprint: settings_fingerprint(settings), verifier_ciphertext: cipher.encrypt_and_sign(verifier, purpose: site.install_id), policy_version: site.membership_version, expires_at: MemberOauthAttempt::LIFETIME.from_now)
        Providers.current.authorization_url(response_type: "code", client_id: settings.fetch("client_id"), redirect_uri: settings.fetch("callback"), scope: scopes(site, linking: !member_session.nil?).join(" "), state: state,
          code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false), code_challenge_method: "S256", prompt: "consent")
      end
    end
    def complete!(state:, code:, issuer:, browser:, callback:)
      raise Invalid unless state.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(state) && code.is_a?(String) && code.bytesize.between?(1, 1024) && !code.match?(/[\x00-\x20\x7f]/) && browser.is_a?(String) && issuer == ISSUER
      expired = false
      reused_code = false
      attempt = Membership.locked do |site|
        item = MemberOauthAttempt.lock.find_by(state_digest: Membership.digest(state))
        raise Invalid unless item && item.site_id == site.id && ActiveSupport::SecurityUtils.secure_compare(item.browser_digest, Membership.digest(browser)) && item.used_at.nil? && item.policy_version == site.membership_version && item.callback == callback && callback == site.canonical_origin + "/login/members/discord/callback" && Policy.method_allowed?(site, "discord") && item.provider_fingerprint == settings_fingerprint(Providers.current.discord_settings(origin: site.canonical_origin))
        unless item.deadline_valid_locked?
          expired = true
          next
        end
        if MemberOauthAttempt.where(code_digest: Membership.digest(code)).exists?
          item.update!(used_at: Time.current)
          reused_code = true
        else
          item.update!(used_at: Time.current, code_digest: Membership.digest(code))
        end
        item
      end
      raise Invalid if expired || reused_code
      # Consumption commits BEFORE network; provider errors/replay cannot retry a code.
      site = attempt.site
      verifier = cipher.decrypt_and_verify(attempt.verifier_ciphertext, purpose: site.install_id)
      linking = attempt.purpose == "link"
      payload = Providers.current.exchange(code: code, verifier: verifier, origin: site.canonical_origin, scopes: scopes(site, linking: linking))
      raise Invalid unless payload.is_a?(Hash) && payload["id"].is_a?(String) && /\A[1-9][0-9]{5,24}\z/.match?(payload["id"]) && !payload["bot"] && !payload["system"]
      requires_email = site.member_email_required || linking
      address = !requires_email || payload["email"].nil? ? nil : Membership.email(payload["email"])
      verified = payload["verified"] == true && address
      raise Invalid if requires_email && !verified
      Membership.locked do |current|
        raise Invalid unless attempt.policy_version == current.membership_version && Policy.method_allowed?(current, "discord") && attempt.provider_fingerprint == settings_fingerprint(Providers.current.discord_settings(origin: current.canonical_origin))
        # Recheck deadline after the bounded exchange, even though it was consumed.
        raise Invalid unless attempt.deadline_valid_locked?
        identity = MemberIdentity.lock.find_by(provider: "discord", subject: payload.fetch("id"))
        if attempt.purpose == "link"
          session = MemberSession.lock.find_by(id: attempt.member_session_id)
          member = session&.member
          member&.lock!
          raise Invalid unless session && member.active? && session.auth_version == member.auth_version && session.fresh_proof?
          raise Collision if identity && identity.member_id != member.id
          raise Invalid unless verified && member.email && address == member.email
          linked = MemberIdentity.lock.find_by(member_id: member.id, provider: "discord")
          raise Collision if linked && linked.subject != payload["id"]
          member.member_identities.create!(provider: "discord", subject: payload["id"]) unless identity
        elsif identity
          member = Member.lock.find(identity.member_id)
          raise Invalid unless member.active? && member.site_id == current.id
          raise Invalid if current.member_email_required && address != member.email
        else
          raise Unavailable unless current.member_registration_enabled
          # No automatic merge by email, including an existing separate Member.
          raise Collision if address && Member.lock.find_by(site: current, email_key: Membership.digest(address))
          member = Member.create!(site: current, public_id: SecureRandom.uuid, email: verified ? address : nil, email_key: verified ? Membership.digest(address) : nil,
            email_verified_at: verified ? Time.current : nil, email_proof: verified ? "discord" : nil)
          member.member_identities.create!(provider: "discord", subject: payload["id"])
        end
        [ member, MemberSession.issue!(member, method: "discord") ]
      end
    rescue ActiveRecord::RecordNotUnique, ActiveSupport::MessageEncryptor::InvalidMessage
      raise Invalid, "This verification could not be accepted", cause: nil
    end
    def disconnect!(session:, confirmation:)
      Membership.locked do |site|
        session.lock!
        member = session.member
        member.lock!
        raise Invalid unless confirmation && session.auth_version == member.auth_version && session.fresh_proof? && member.active? && member.email_proof == "mailbox" && Policy.method_allowed?(site, "email")
        Membership.revoke!(member)
        member.member_identities.where(provider: "discord").delete_all
        [ member, MemberSession.issue!(member, method: "email") ]
      end
    end
  end
end
