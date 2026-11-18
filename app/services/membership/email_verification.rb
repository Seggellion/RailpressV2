module Membership
  module EmailVerification
    module_function
    def signer = Rails.application.message_verifier("railpress.member.mailbox.v1")
    def request!(browser:, address:, client:, member_session: nil)
      raise Invalid unless browser.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(browser)
      address = Membership.email(address)
      token = nil
      record = Membership.locked do |site|
        raise Unavailable unless Policy.method_allowed?(site, "email")
        MemberThrottle.consume!(scope: "email-ip", identity: client, limit: 10, window: 15.minutes)
        MemberThrottle.consume!(scope: "email-address", identity: address, limit: 3, window: 15.minutes)
        MemberThrottle.consume!(scope: "email-site", identity: site.id, limit: 100, window: 1.hour)
        member = nil
        if member_session
          member_session.lock!
          member = member_session.member
          member.lock!
          raise Invalid unless member_session.auth_version == member.auth_version && member.active? && member_session.fresh_proof?
        end
        purpose = member ? "change_email" : "signin"
        token = signer.generate({ "nonce" => SecureRandom.hex(32), "audience" => site.install_id, "purpose" => purpose }, purpose: "member-mailbox")
        MemberChallenge.where(site: site, email_key: Membership.digest(address), used_at: nil).update_all(used_at: Time.current, state: "consumed")
        Membership.prune!
        MemberChallenge.create!(site: site, member: member, member_session: member_session, auth_version: member&.auth_version, purpose: purpose,
          browser_digest: Membership.digest(browser), email: address, email_key: Membership.digest(address), token_digest: Membership.digest(token), policy_version: site.membership_version, expires_at: MemberChallenge::LIFETIME.from_now)
      end
      begin
        delivered = Providers.current.deliver_email(address: address, token: token, origin: record.site.canonical_origin)
        raise Unavailable unless delivered == true
        record.with_lock { record.update!(state: "delivered") if record.state == "pending" && record.used_at.nil? }
      rescue StandardError
        record.with_lock { record.update!(state: "failed", used_at: Time.current) }
        # Public response stays identical for delivery failure/account existence.
      end
      nil
    end
    def complete!(browser:, token:, member_session: nil)
      raise Invalid unless browser.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(browser)
      raise Invalid unless token.is_a?(String) && token.bytesize.between?(64, 2048)
      payload = signer.verified(token, purpose: "member-mailbox")
      raise Invalid unless payload.is_a?(Hash)
      failure = false
      result = Membership.locked do |site|
        record = MemberChallenge.lock.find_by(token_digest: Membership.digest(token))
        raise Invalid unless record && record.site_id == site.id && record.browser_digest.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(record.browser_digest, Membership.digest(browser)) && payload["audience"] == site.install_id && payload["purpose"] == record.purpose && record.used_at.nil? && record.state == "delivered" && record.policy_version == site.membership_version && Policy.method_allowed?(site, "email")
        unless record.deadline_valid_locked?
          failure = true
          next
        end
        member = record.member_id ? Member.lock.find(record.member_id) : Member.lock.find_by(site: site, email_key: record.email_key)
        if record.purpose == "change_email"
          raise Invalid unless member&.active? && member.auth_version == record.auth_version && member_session && record.member_session_id == member_session.id
          member_session.lock!
          raise Invalid unless member_session.auth_version == member.auth_version && member_session.fresh_proof?
          raise Collision if Member.where(site: site, email_key: record.email_key).where.not(id: member.id).exists?
          Membership.revoke!(member)
          member.update!(email: record.email, email_key: record.email_key, email_verified_at: Time.current, email_proof: "mailbox")
        else
          raise Invalid if member && !member.active?
          unless member
            raise Unavailable unless site.member_registration_enabled
            member = Member.create!(site: site, public_id: SecureRandom.uuid, email: record.email, email_key: record.email_key, email_verified_at: Time.current, email_proof: "mailbox")
          end
          member.update!(email_verified_at: Time.current, email_proof: "mailbox")
        end
        record.update!(used_at: Time.current, state: "consumed")
        [ member, MemberSession.issue!(member, method: "email") ]
      end
      raise Invalid if failure
      result
    end
  end
end
