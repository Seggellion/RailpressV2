# frozen_string_literal: true

require "json"
require "digest"

module Railpress
  # Nonsecret installation intent. Host credentials are never serialized here.
  module MediaConfiguration
    class Invalid < StandardError; end
    FIELDS = %w[version backend project bucket prefix auth_method identity_source disk_root].freeze
    SOURCES = %w[automatic attached federation native development].freeze
    INLINE_CREDENTIALS = %w[GOOGLE_PRIVATE_KEY GOOGLE_CLIENT_SECRET GOOGLE_REFRESH_TOKEN].freeze
    module_function

    def bucket?(value)
      value.is_a?(String) && value.bytesize.between?(3, 222) &&
        !value.start_with?("goog") && !value.match?(/google|g00gle|\A\d+\.\d+\.\d+\.\d+\z/) &&
        value.split(".", -1).all? { |part| part.bytesize.between?(1, 63) && part.match?(/\A[a-z0-9](?:[a-z0-9_-]*[a-z0-9])?\z/) }
    end

    def prefix!(value)
      raise Invalid, "Use an empty prefix or slash-separated letters, numbers, underscores and hyphens (at most 128 bytes)." unless
        value.is_a?(String) && value.bytesize <= 128 && (value.empty? || value.split("/", -1).all? { |part| part.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/) })
      value
    end

    def selection(fields, disk_root: "")
      raise Invalid, "Choose Disk or Google Cloud Storage." unless fields.is_a?(Hash) && %w[local gcs].include?(fields["backend"])
      if fields["backend"] == "local"
        raise Invalid, "The operator must configure an absolute Disk directory." unless disk_root.is_a?(String) && (disk_root.empty? || disk_root.start_with?("/")) && !disk_root.match?(/[\x00-\x1f]/)
        return { "version" => 1, "backend" => "local", "disk_root" => disk_root }
      end
      raise Invalid, "Use a Google Cloud project ID of 6–30 lowercase letters, numbers and hyphens." unless fields["project"].is_a?(String) && fields["project"].match?(/\A[a-z][a-z0-9-]{4,28}[a-z0-9]\z/)
      raise Invalid, "Use a valid existing GCS bucket name, not a URL or IP address." unless bucket?(fields["bucket"])
      prefix = prefix!(fields.fetch("prefix", ""))
      method = fields.fetch("auth_method", "adc")
      source = fields.fetch("identity_source", "automatic")
      raise Invalid, "Choose ADC or the explicit operator-managed service-account fallback." unless %w[adc service_account_file].include?(method)
      raise Invalid, "Choose a supported ADC environment." unless SOURCES.include?(source)
      { "version" => 1, "backend" => "gcs", "project" => fields["project"], "bucket" => fields["bucket"], "prefix" => prefix,
        "auth_method" => method, "identity_source" => method == "adc" ? source : "native" }
    end

    def validate!(value)
      raise Invalid, "Invalid media configuration." unless value.is_a?(Hash) && value["version"] == 1 && (value.keys - FIELDS).empty?
      canonical = selection(value, disk_root: value.fetch("disk_root", ""))
      raise Invalid, "Media configuration contains unexpected fields." unless canonical == value
      canonical
    end

    def fingerprint(value) = Digest::SHA256.hexdigest(JSON.generate(validate!(value).sort.to_h))

    def environment(env = ENV, disk_root: "")
      selection({ "backend" => env.fetch("RAILPRESS_STORAGE_BACKEND", "local"), "project" => env.fetch("RAILPRESS_GCS_PROJECT", ""),
        "bucket" => env.fetch("RAILPRESS_GCS_BUCKET", ""), "prefix" => env.fetch("RAILPRESS_GCS_PREFIX", ""),
        "auth_method" => env.fetch("RAILPRESS_GCS_AUTH_METHOD", "adc"), "identity_source" => env.fetch("RAILPRESS_GCS_ADC_SOURCE", "automatic") }, disk_root: disk_root)
    end

    def credential_document!(path, type: nil)
      raise Invalid, "The operator credential file is unavailable or unsafe." unless path.is_a?(String) && path.start_with?("/") && File.realpath(path) == path
      stat = File.lstat(path)
      raise Invalid, "The operator credential file must be owned, private, regular and bounded." unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size.between?(2, 65_536)
      ancestor = File.dirname(path)
      loop do
        raise Invalid, "Credential files must be outside Git repositories and application releases." if File.exist?(File.join(ancestor, ".git"))
        break if ancestor == "/"
        ancestor = File.dirname(ancestor)
      end
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        raise Invalid, "Credential files must be outside application releases." if path.start_with?(Rails.root.realpath.to_s + "/")
      end
      value = JSON.parse(File.binread(path))
      raise Invalid, "Unsupported operator credential type." unless value.is_a?(Hash) && %w[service_account external_account authorized_user].include?(value["type"]) && (!type || value["type"] == type)
      source = value["credential_source"]
      raise Invalid, "Invalid federation credential source." if source && !source.is_a?(Hash)
      raise Invalid, "Executable federation credential sources are unsupported." if source && source["executable"]
      value
    rescue SystemCallError, JSON::ParserError
      raise Invalid, "The operator credential file is unavailable or invalid.", cause: nil
    end

    def adc_path(env = ENV, home: Dir.home)
      explicit = env["GOOGLE_APPLICATION_CREDENTIALS"]
      return explicit if explicit && !explicit.empty?
      # These are the pinned googleauth native-Linux lookup paths. A custom
      # gcloud CLI directory is not automatically an ADC discovery override.
      [ File.join(env.fetch("HOME", home), ".config/gcloud/application_default_credentials.json"),
        "/etc/google/auth/application_default_credentials.json" ].find { |path| File.file?(path) }
    end

    def inline_credentials?(env)
      env["RAILPRESS_UNSUPPORTED_GOOGLE_INLINE"] == "1" || INLINE_CREDENTIALS.any? { |key| env[key] && !env[key].empty? }
    end

    # Inspection only: never invokes ADC discovery, metadata, token or bucket APIs.
    def credential_status(config, env: ENV, home: Dir.home)
      if config["auth_method"] == "service_account_file"
        credential_document!(env["RAILPRESS_GCS_CREDENTIALS_FILE"], type: "service_account")
        return { "state" => "CONFIGURED", "detail" => "Explicit private operator service-account file is visible. Token issuance and provider permissions are NOT TESTED." }
      end
      raise Invalid, "ADC selected: remove the fallback credential setting or explicitly select fallback; no automatic switch is performed." if env["RAILPRESS_GCS_CREDENTIALS_FILE"] && !env["RAILPRESS_GCS_CREDENTIALS_FILE"].empty?
      raise Invalid, "Inline credentials are unsupported; provision an explicit private source." if inline_credentials?(env)
      path = adc_path(env, home: home)
      if path
        doc = credential_document!(path)
        raise Invalid, "Attached identity conflicts with a local ADC file." if config["identity_source"] == "attached"
        raise Invalid, "Federation requires an operator-provisioned external-account ADC configuration." if config["identity_source"] == "federation" && doc["type"] != "external_account"
        raise Invalid, "Service-account keys require the explicitly selected fallback method." if doc["type"] == "service_account"
        return { "state" => "CONFIGURED", "detail" => doc["type"] == "authorized_user" ? "Local development ADC is visible; this is not production workload identity or provider proof." : "External-account ADC configuration is visible; federation/token/provider access is NOT TESTED." }
      end
      return { "state" => "CONFIGURED", "detail" => "The operator declares attached workload identity. Metadata availability, tokens and provider permissions are NOT TESTED." } if config["identity_source"] == "attached"
      { "state" => "ACTION REQUIRED", "detail" => "No local ADC source is visible. Ask the operator to configure ADC/federation, or explicitly declare the attached workload identity. No metadata server was contacted." }
    rescue Invalid
      { "state" => "ACTION REQUIRED", "detail" => "Selected credentials are missing, unsafe or inconsistent. Follow operator instructions; no fallback or provider request occurred." }
    end

    def credentials(method:, file: nil, identity_source: "automatic")
      require "googleauth"
      scope = [ "https://www.googleapis.com/auth/devstorage.read_write" ]
      if method == "service_account_file"
        credential_document!(file, type: "service_account")
        File.open(file, "rb") { |io| Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: io, scope: scope) }
      elsif method == "adc"
        # Explicit supported ADC, not Storage's separate credential aliases.
        raise Invalid, "Unexpected fallback credentials under ADC." if file
        raise Invalid, "Inline credentials are unsupported." if inline_credentials?(ENV)
        path = adc_path
        if path
          doc = credential_document!(path)
          raise Invalid, "Keys require explicit fallback." if doc["type"] == "service_account" || identity_source == "attached"
          raise Invalid, "Federation configuration missing." if identity_source == "federation" && doc["type"] != "external_account"
        elsif %w[federation native development].include?(identity_source)
          raise Invalid, "The selected ADC source is unavailable; no fallback was attempted."
        end
        Google::Auth.get_application_default(scope)
      else
        raise Invalid, "Unsupported authentication method."
      end
    end
  end
end
