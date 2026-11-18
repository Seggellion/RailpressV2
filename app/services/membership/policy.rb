module Membership
  module Policy
    MODES = %w[disabled email discord both].freeze
    module_function
    def enabled_methods(mode) = { "disabled" => [], "email" => [ "email" ], "discord" => [ "discord" ], "both" => %w[email discord] }.fetch(mode) { raise Invalid }
    def selection(fields)
      mode = fields.fetch("membership_mode", "disabled")
      raise Invalid unless MODES.include?(mode)
      { "membership_mode" => mode, "member_registration_enabled" => fields["member_registration_enabled"].to_s == "1",
        "member_email_required" => fields.fetch("member_email_required", "1").to_s == "1" }
    end
    def validate!(choices, providers: Providers.current, origin:)
      raise Invalid unless MODES.include?(choices.fetch("membership_mode"))
      if choices["member_registration_enabled"]
        list = enabled_methods(choices["membership_mode"])
        raise Unavailable if list.empty? || list.any? { |method| !providers.ready?(method, origin: origin) }
      end
      choices
    end
    def method_allowed?(site, method)
      enabled_methods(site.membership_mode).include?(method) && Providers.current.ready?(method, origin: site.canonical_origin)
    end
    def configure!(actor:, revision:, fields:)
      raise Identity::Capabilities::Denied unless actor.is_a?(User)
      version = actor.auth_version
      Membership.locked do |site|
        actor.lock!
        raise Identity::Capabilities::Denied unless actor.auth_version == version
        Identity::Capabilities.require!(actor, :manage_identity)
        raise Conflict unless revision.to_s == site.membership_version.to_s
        choices = validate!(selection(fields), origin: site.canonical_origin)
        site.update!(choices.merge("membership_version" => site.membership_version + 1))
        Member.where(site: site).order(:id).find_each { |member| Membership.revoke!(member) }
        Activity::Recorder.record!(actor: actor, action: "identity.membership_configured", subject: site)
        site
      end
    end
  end
end
