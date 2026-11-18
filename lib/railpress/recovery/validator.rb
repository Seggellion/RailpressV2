# frozen_string_literal: true

module Railpress
  module Recovery
    class Validator
      STATUSES = %w[VERIFIED MISSING MISMATCH INACCESSIBLE UNSUPPORTED UNKNOWN].freeze
      attr_reader :checks
      def initialize(manifest:, dump:, app_root:, configuration_files:, theme_root:, store:)
        @manifest, @dump, @app_root, @configuration_files, @theme_root, @store = manifest, dump, app_root, configuration_files, theme_root, store
        @checks = {}
      end
      def check(name)
        value = yield
        @checks[name] = value == true ? "VERIFIED" : (STATUSES.include?(value) ? value : "MISMATCH")
      rescue Gcs::Failure => error
        @checks[name] = error.status
      rescue Errno::ENOENT
        @checks[name] = "MISSING"
      rescue Errno::EACCES
        @checks[name] = "INACCESSIBLE"
      rescue NativeHost::DatabaseIntegrity::SchemaMismatch
        @checks[name] = "MISMATCH"
      rescue Error, JSON::ParserError, KeyError, TypeError, ArgumentError
        @checks[name] = "UNSUPPORTED"
      rescue StandardError
        @checks[name] = "UNKNOWN"
      end
      def run(database: nil, revoked: false)
        # Each observation is independent: an earlier unavailable resource must
        # neither poison a later result nor survive as a stale VERIFIED check.
        @checks.clear
        check("manifest") { Manifest.validate!(@manifest); true }
        return report unless checks["manifest"] == "VERIFIED"
        check("dump") do
          stat = File.lstat(@dump)
          stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? &&
            stat.size == @manifest["database"]["dump_bytes"] && Recovery.sha(@dump) == @manifest["database"]["dump_sha256"]
        end
        check("application") { Manifest.application(@app_root, @manifest["database"]["engine"]) == @manifest["application"] }
        check("configuration") { Manifest.configuration(@configuration_files) == @manifest["configuration"] }
        check("themes") { Manifest.themes(@theme_root) == @manifest["themes"] }
        @manifest["media"].each_with_index { |object, index| check("media_#{index}") { @store ? @store.verify(object) : "UNKNOWN" } }
        check("security_requirements") { @manifest["security"].except("password_verifiers_sha256") == Manifest::SECURITY }
        if database
          check("database_identity") do
            database.assert_installation!
            database.instance_variable_get(:@config).data["engine"] == @manifest["database"]["engine"]
          end
          check("schema_and_records") { database.integrity.verify!(@manifest["database"]["integrity"], revoked: revoked) }
          check("media_references") { Manifest.media(database) == @manifest["media"] }
        else
          checks["restored_database"] = "UNKNOWN"
        end
        report
      end
      def report
        { "format" => "railpress.recovery-validation.v1", "status" => checks.values.all? { |v| v == "VERIFIED" } ? "VERIFIED" : "UNKNOWN", "checks" => checks.dup,
          "provider_policy" => @store ? @store.policy_status : { "iam" => "UNKNOWN" }, "provider_qualification" => "NOT ATTESTED", "application_http" => "NOT TESTED" }
      end
    end
  end
end
