# frozen_string_literal: true

module Railpress
  module Recovery
    class Candidate
      def self.check!(target:, app_root:, clock_root:, configuration_files:, theme_root: nil)
        secrets = Releases.parse(Recovery.private_file(configuration_files.fetch("application_secrets"), maximum: 16_384), limit: 16_384)
        Releases.keys!(secrets, %w[SECRET_KEY_BASE])
        raise Error, "candidate_secret" unless secrets["SECRET_KEY_BASE"].is_a?(String) && secrets["SECRET_KEY_BASE"].bytesize.between?(64, 256)
        database, identity = target.database!
        env = { "PATH" => File.dirname(RbConfig.ruby) + ":/usr/bin:/bin", "HOME" => ENV.fetch("HOME"),
          "RAILS_ENV" => "production", "SECRET_KEY_BASE" => secrets["SECRET_KEY_BASE"], "DISABLE_BOOTSNAP" => "1",
          "BUNDLE_GEMFILE" => File.join(app_root, "Gemfile"), "RAILPRESS_PRIVATE_STATE_ROOT" => clock_root,
          "RAILPRESS_HTTPS_ORIGIN" => "https://localhost", "RAILPRESS_STORAGE_BACKEND" => "gcs",
          "RAILPRESS_RECOVERY_INSTALL_ID" => target.data["install_id"], "RAILPRESS_RECOVERY_DB_NAME" => identity["database"] }
        env["RAILPRESS_THEME_ROOT"] = theme_root if theme_root
        %w[RAILPRESS_WEBP_DECODER LD_LIBRARY_PATH GEM_HOME GEM_PATH].each { |key| env[key] = ENV[key] if ENV[key] }
        { "ADAPTER" => "adapter", "HOST" => "host", "PORT" => "port", "NAME" => "database", "USER" => "username", "PASSWORD" => "password" }.each do |key, field|
          env["RAILPRESS_DB_#{key}"] = database[field].to_s
        end
        # Deliberately do not pass cloud, SMTP, Discord, queue-worker or restored
        # provider environment. This probe boots Rails and Rack requests only.
        output = target.path("run", "candidate-probe.json")
        NativeHost::Commands.run([ RbConfig.ruby, File.join(app_root, "bin/railpress-recovery-probe") ], env: env, chdir: app_root,
          output: output, log: target.path("logs", "candidate-probe.log"), seconds: 30)
        result = Releases.parse(F.read(output, maximum: 16_384), limit: 16_384)
        raise Error, "candidate_readiness" unless result["status"] == "VERIFIED" && result["database"] == identity["database"] && result["install_id"] == target.data["install_id"] && result["scheduling_held"] == true
        result
      end
    end
  end
end
