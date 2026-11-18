# frozen_string_literal: true

module Installation
  module Cli
    module_function
    def ask(label, default: nil, secret: false)
      print "#{label}#{default.nil? ? '' : " [#{default}]"}: "
      line = secret ? $stdin.noecho(&:gets) : $stdin.gets
      puts if secret
      raise Progress::Invalid, "Input ended; private progress retained." unless line
      value = line.chomp
      value.empty? && !default.nil? ? default : value
    end

    def doctor(state)
      # Intentionally no database connection, directory creation, schema writes or repair.
      { "product_version" => Railpress::Product::VERSION, "release_channel" => Railpress::Product::CHANNEL,
        "installation" => state.public_status.slice(:installed), "environment" => Environment.call,
        "database" => Configuration.public_fields, "target_fingerprint" => Configuration.fingerprint,
        "repairs_performed" => false, "database_probed" => false }
    end

    def prepare_schema(state)
      puts "Explicit schema preparation for the operator-configured dedicated database:"
      puts JSON.pretty_generate(Configuration.public_fields)
      puts "Target fingerprint: #{Configuration.fingerprint}"
      confirmation = ask("Retype the entire target fingerprint to authorize forward migrations")
      Schema.prepare!(state: state, confirmation: confirmation)
      puts "Schema ready. No unrelated table was dropped. Return to the browser database step or rerun install."
    end

    def install(state)
      raise Railpress::BootstrapState::Closed, "Setup is closed" if state.installed?
      wizard = Wizard.new(state)
      claim = state.claim!(ask("One-time setup secret", secret: true))
      wizard.start!(claim)
      loop do
        value = wizard.progress.read
        step = value.fetch("step")
        fields = case step
        when "environment"
          puts JSON.pretty_generate(Environment.call)
          ask("Press Enter to validate required checks")
          {}
        when "database"
          puts JSON.pretty_generate(Configuration.public_fields)
          puts "Adapter and connection settings are operator-managed; changing them requires a host config change and Rails restart."
          Configuration.public_fields.merge("use_operator_credentials" => "1")
        when "storage"
          puts "Google Cloud Storage with ADC/Workload Identity is recommended for production. Disk requires verified persistent storage and backups."
          backend = ask("Media storage: gcs or local", default: "gcs")
          chosen = { "backend" => backend }
          if backend == "gcs"
            chosen.merge!("project" => ask("Google Cloud project ID"), "bucket" => ask("Existing private GCS bucket"), "prefix" => ask("Object prefix (optional)", default: ""),
              "auth_method" => ask("Authentication: adc or service_account_file", default: "adc"), "identity_source" => ask("ADC environment: automatic, attached, federation, native or development", default: "automatic"))
          end
          puts "Only local configuration is checked. No cloud objects, credentials, IAM or retention are changed. Web/worker agreement and live-provider validation remain pending."
          chosen["storage_limits_ack"] = ask("Acknowledge provider/durability and worker checks remain pending?1=yes", default: "0")
          chosen
        when "identity"
          { "title" => ask("Site name"), "tagline" => ask("Tagline (optional)"),
            "canonical_origin" => ask("Canonical HTTPS origin", default: Configuration.canonical_origin),
            "timezone" => ask("IANA timezone", default: "Etc/UTC"), "locale" => "en",
            "home_mode" => ask("Homepage: static or blog", default: "static"),
            "indexing_enabled" => ask("Approve search-engine indexing? Type 1 for yes", default: "0") }
        when "owner"
          { "username" => ask("Owner username"), "email" => ask("Owner email"),
            "password" => ask("Owner password", secret: true), "password_confirmation" => ask("Confirm password", secret: true) }
        when "appearance"
          { "brand_label" => ask("Brand name (optional)"), "about" => ask("Include About starter? 1=yes", default: "1"),
            "contact" => ask("Include Contact starter? 1=yes", default: "1") }
        when "membership"
          puts "Membership is independent of your local Owner. No secrets are entered here; providers are configured by your host operator."
          { "membership_mode" => ask("Member verification: disabled, email, discord or both", default: "disabled"),
            "member_email_required" => ask("Require verified email for Discord?1=yes", default: "1"),
            "member_registration_enabled" => ask("Explicitly enable new member registration after provider readiness?1=yes", default: "0") }
        when "review"
          puts JSON.pretty_generate(wizard.redacted)
          raise Progress::Invalid, "Activation cancelled; private progress retained." unless ask("Type INSTALL to activate") == "INSTALL"
          Finish.call(state: state, claim: claim, revision: value.fetch("revision"))
          puts "Website initialized and setup sealed. Sign in at #{Configuration.canonical_origin}/login. Review Site Readiness before sharing."
          return
        end
        saved = wizard.advance!(claim: claim, revision: value.fetch("revision"), step: step, fields: fields)
        if step == "storage" && saved["step"] == "storage"
          puts JSON.pretty_generate(MediaLibrary::Configuration.observe(saved.dig("data", "storage")))
          raise Configuration::Handoff, "Storage choice saved. Apply the host configuration, restart processes and resume install. No provider was contacted."
        end
      end
    end
  end
end
