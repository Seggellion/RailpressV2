# frozen_string_literal: true

module Installation
  module Configuration
    class Handoff < StandardError; end
    module_function

    def active
      ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
    end

    def public_fields
      config = active
      { "adapter" => config.fetch("adapter"), "host" => config.fetch("host"), "port" => config.fetch("port").to_s,
        "database" => config.fetch("database"), "username" => config.fetch("username"),
        "tls" => (config["sslmode"] || config["ssl_mode"] || "local").to_s }
    end

    def fingerprint
      config = active
      Digest::SHA256.hexdigest(JSON.generate(config.slice("adapter", "host", "port", "database", "username", "sslmode", "sslrootcert", "ssl_mode", "sslca").sort.to_h))
    end

    def validate_submission!(fields)
      expected = public_fields
      supplied = fields.to_h.stringify_keys
      raise Handoff, "Database settings are operator-managed. Apply the selected configuration through the host operator, restart Railpress, then return to this step." unless expected.all? { |key, value| supplied[key].to_s == value.to_s }
      unless supplied["use_operator_credentials"] == "1"
        given = Digest::SHA256.hexdigest(supplied["password"].to_s)
        correct = Digest::SHA256.hexdigest(active["password"].to_s)
        raise Handoff, "The supplied credentials do not match the operator-managed connection. No alternate endpoint was contacted." unless ActiveSupport::SecurityUtils.secure_compare(given, correct)
      end
      raise Handoff, "Use a dedicated database with a bounded identifier." unless /\A[a-zA-Z0-9_]{1,63}\z/.match?(expected["database"])
      true
    end

    def canonical_origin
      value = ENV["RAILPRESS_HTTPS_ORIGIN"]
      raise Progress::Invalid, "The operator must configure a fixed HTTPS origin before installation." unless value
      Railpress::SiteOrigin.new(value).to_s
    end
  end
end
