# frozen_string_literal: true

module Installation
  class Wizard
    attr_reader :state, :progress
    def initialize(state)
      @state = state
      @progress = Progress.new(state)
    end

    def start!(claim) = progress.start!(claim)

    def advance!(claim:, revision:, step:, fields: {})
      fields = fields.to_h.stringify_keys
      raise Progress::Invalid, "Unknown installation step." unless Progress::STEPS[0...-1].include?(step)
      progress.update!(claim: claim, revision: revision) do |value|
        index = Progress::STEPS.index(step)
        raise Progress::Invalid, "Complete the preceding steps first." unless (Progress::STEPS.take(index) - value["completed"]).empty?
        if step == "storage"
          data = MediaLibrary::Configuration.selection(fields.to_h.stringify_keys)
          value["data"][step] = data
          report = MediaLibrary::Configuration.observe(data, probe_disk: true)
          value["completed"] = Progress::STEPS.take(index)
          value["step"] = step
          next unless report["state"] == "CONFIGURED"
          raise Progress::Invalid, "Acknowledge the unverified provider/durability and worker requirements before continuing." unless fields["storage_limits_ack"] == "1"
          value["completed"] = Progress::STEPS.take(index + 1)
          value["step"] = Progress::STEPS[index + 1]
          next
        end
        data = validate(step, fields.to_h.stringify_keys)
        value["data"][step] = data
        value["completed"] = Progress::STEPS.take(index + 1)
        value["step"] = Progress::STEPS[index + 1]
        value["configuration"] = Configuration.fingerprint if step == "database"
      end
    end

    def validate(step, fields)
      case step
      when "environment"
        cells = Environment.call
        raise Progress::Invalid, "Required environment checks need operator attention. Review the report below." unless Environment.required_ready?(cells)
        { "checked" => true }
      when "database"
        Configuration.validate_submission!(fields)
        result = DatabaseProbe.call
        raise Schema::Refused, "Connection verified. The operator must run bin/railpress install --prepare-schema and confirm the displayed target, then retry this step." unless Schema.ready?(state)
        result.slice("adapter", "schema", "configuration")
      when "identity"
        origin = Configuration.canonical_origin
        raise Progress::Invalid, "The canonical URL must match the fixed operator HTTPS origin." unless fields["canonical_origin"] == origin
        attributes = fields.slice("title", "tagline", "canonical_origin", "timezone", "locale", "home_mode")
        attributes["indexing_enabled"] = fields["indexing_enabled"] == "1"
        record = Site.new(attributes.merge("singleton_key" => 1, "install_id" => SecureRandom.uuid, "owner" => User.new(role: "owner")))
        record.valid?
        errors = record.errors.reject { |error| error.attribute == :owner }
        raise Progress::Invalid, errors.map(&:full_message).join(". ") if errors.any?
        attributes
      when "owner"
        record = User.new(fields.slice("username", "email", "password", "password_confirmation").merge("role" => "owner"))
        raise Progress::Invalid, record.errors.full_messages.join(". ") unless record.valid?
        { "username" => record.username, "email" => record.email, "password_digest" => record.password_digest }
      when "membership"
        begin
          Membership::Policy.validate!(Membership::Policy.selection(fields), origin: Configuration.canonical_origin)
        rescue Membership::Invalid, Membership::Unavailable
          raise Progress::Invalid, "Choose a valid membership policy. Leave registration disabled until your host operator verifies every selected provider. Owner setup remains local and independent."
        end
      when "appearance"
        Environment.candidate
        brand = fields.fetch("brand_label", "").strip
        raise Progress::Invalid, "Brand name must be at most 100 characters without markup or control characters." if brand.length > 100 || brand.match?(/[<>\x00-\x1f]/)
        { "brand_label" => brand, "about" => fields["about"] == "1", "contact" => fields["contact"] == "1" }
      end
    end

    def redacted
      value = progress.read.deep_dup
      owner = value.dig("data", "owner")
      value["data"]["owner"] = { "username" => owner["username"], "password" => "Set securely; never displayed" } if owner
      value.except("claim_binding", "attempt_id")
    end
  end
end
