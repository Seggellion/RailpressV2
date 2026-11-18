# frozen_string_literal: true

module Railpress
  module Recovery
    class Manifest
      FORMAT = "railpress.backup.v1"
      LIMIT = 8 * 1024 * 1024
      MAX_DUMP = 256 * 1024 * 1024
      FIELDS = %w[format id database application site consistency media configuration themes security limitations].freeze
      SECURITY = { "rotate_clock" => true, "revoke_ephemeral" => true, "hold_scheduling" => true,
        "workers_stopped" => true, "password_verifiers_unchanged" => true }.freeze
      CONFIGURATION = %w[application_secrets membership_provider release_trust themes_configuration].freeze
      def self.application(root, engine)
        inventory = {}
        %w[app config db lib public vendor themes Gemfile Gemfile.lock .ruby-version].each do |entry|
          path = File.join(root, entry)
          files = File.directory?(path) ? Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort : [ path ]
          files.each do |file|
            raise Error, "application_symlink" if File.symlink?(file)
            next unless File.file?(file)
            next if file.start_with?(File.join(root, "public/assets/"))
            relative = file.delete_prefix(root + "/")
            inventory[relative] = Recovery.sha(file)
            raise Error, "application_inventory_limit" if inventory.length > 4096
          end
        end
        { "version" => Product::VERSION, "schema" => Product::SCHEMA, "source_sha256" => Recovery.digest(inventory),
          "schema_file_sha256" => Recovery.sha(File.join(root, "db/schema_#{engine}.rb")),
          "migrations_sha256" => Recovery.digest(inventory.select { |name, _| name.start_with?("db/migrate/") }) }
      end
      def self.configuration(files)
        raise Error, "configuration_inventory" unless files.is_a?(Hash) && files.keys.all? { |key| CONFIGURATION.include?(key) } && files.key?("application_secrets")
        files.transform_values { |path| Digest::SHA256.hexdigest(Recovery.private_file(path, maximum: 65_536)) }
      end
      def self.themes(root)
        raise Error, "theme_root" unless File.directory?(root) && !File.symlink?(root)
        files = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
        raise Error, "theme_inventory_limit" if files.length > 4096
        files.filter_map do |file|
          raise Error, "theme_symlink" if File.symlink?(file)
          [ file.delete_prefix(root + "/"), Recovery.sha(file) ] if File.file?(file)
        end.to_h
      end
      def self.media(database)
        rows = database.query("SELECT a.id,a.blob_id,a.thumbnail_blob_id,a.sha256,a.thumbnail_sha256,a.retained_objects FROM media_assets a ORDER BY a.id LIMIT 1001")
        raise Error, "media_inventory_limit" if rows.length > 1000
        objects = rows.flat_map do |asset|
          retained = asset["retained_objects"]
          retained = JSON.parse(retained) if retained.is_a?(String)
          raise Error, "media_tombstone" unless retained.nil? || (retained.is_a?(Array) && retained.length <= 2)
          Array(retained).each { |binding| validate_object!(binding) }
          Array(retained) + [ [ "blob_id", "sha256" ], [ "thumbnail_blob_id", "thumbnail_sha256" ] ].filter_map do |column, checksum|
            next unless asset[column]
            id = Integer(asset[column])
            blob = database.query("SELECT id,\"key\",metadata,byte_size,service_name FROM active_storage_blobs WHERE id=#{id}".gsub('"key"', database.quote_identifier("key"))).first
            raise Error, "media_blob_missing" unless blob
            metadata = blob["metadata"].is_a?(Hash) ? blob["metadata"] : JSON.parse(blob.fetch("metadata"))
            binding = metadata["railpress_gcs"]
            raise Error, "media_backend_unsupported" unless binding.is_a?(Hash) && blob["service_name"] == "gcs" && binding["sha256"] == asset[checksum] && binding["key"] == blob["key"] && binding["byte_size"] == blob["byte_size"].to_i
            validate_object!(binding)
            binding
          end
        end
        objects.uniq.sort_by { |row| [ row["bucket"], row.fetch("prefix", ""), row["key"] ] }
      end
      def self.validate_object!(object)
        Releases.keys!(object, %w[bucket project key generation byte_size sha256] + (object.is_a?(Hash) && object.key?("prefix") ? [ "prefix" ] : []))
        Gcs::Store.new(bucket: object["bucket"], project: object["project"], prefix: object.fetch("prefix", "")).key!(object["key"])
        Releases.identity!(object["sha256"])
        raise Error, "media_generation" unless object["generation"].is_a?(String) && object["generation"].match?(/\A[1-9][0-9]{0,19}\z/)
        Releases.integer!(object["byte_size"], 1, Gcs::MAX_BYTES)
      end
      def self.load(path, trusted_sha256:)
        Releases.identity!(trusted_sha256)
        bytes = Recovery.private_file(path, maximum: LIMIT)
        raise Error, "manifest_authentication" unless Digest::SHA256.hexdigest(bytes) == trusted_sha256
        document = Releases.parse(bytes, limit: LIMIT)
        validate!(document)
      end
      def self.validate!(document)
        Releases.keys!(document, FIELDS)
        raise Error, "manifest_version" unless document["format"] == FORMAT
        NativeHost.uuid!(document["id"])
        Releases.keys!(document["database"], %w[engine version source dump_sha256 dump_bytes integrity])
        db = document["database"]
        major = { "postgresql" => "16.", "mysql2" => "8.4." }[db["engine"]]
        raise Error, "database_version" unless major && db["version"].is_a?(String) && db["version"].start_with?(major)
        Releases.identity!(db["dump_sha256"])
        Releases.integer!(db["dump_bytes"], 1, MAX_DUMP)
        Releases.keys!(document["site"], %w[install_id])
        NativeHost.uuid!(document["site"]["install_id"])
        Releases.keys!(document["application"], %w[version schema source_sha256 schema_file_sha256 migrations_sha256])
        %w[source_sha256 schema_file_sha256 migrations_sha256].each { |key| Releases.identity!(document["application"][key]) }
        Releases.keys!(document["consistency"], %w[method observed_at clock_binding_sha256])
        raise Error, "backup_consistency" unless document["consistency"]["method"] == "offline-before-dump-after-equal-v1"
        Releases.identity!(document["consistency"]["clock_binding_sha256"])
        raise Error, "restore_security_requirements" unless document["security"].is_a?(Hash) && document["security"].except("password_verifiers_sha256") == SECURITY
        Releases.identity!(document["security"]["password_verifiers_sha256"])
        raise Error, "media_inventory" unless document["media"].is_a?(Array) && document["media"].length <= 2000
        document["media"].each { |object| validate_object!(object) }
        raise Error, "media_inventory_duplicate" unless document["media"].map { |row| [ row["bucket"], row.fetch("prefix", ""), row["key"] ] }.uniq.length == document["media"].length
        configuration = document["configuration"]
        raise Error, "configuration_inventory" unless configuration.is_a?(Hash) && configuration.key?("application_secrets") && configuration.keys.all? { |key| CONFIGURATION.include?(key) }
        configuration.each_value { |value| Releases.identity!(value) }
        raise Error, "theme_inventory" unless document["themes"].is_a?(Hash) && document["themes"].length <= 4096
        document["themes"].each do |name, value|
          raise Error, "theme_inventory_path" unless name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_.\/-]+\z/) && !name.start_with?("/") && !name.split("/").include?("..")
          Releases.identity!(value)
        end
        raise Error, "manifest_limitations" unless document["limitations"] == limitations
        document
      end
      def self.limitations
        %w[database-rewind-only retained-live-gcs-required no-media-disaster-backup no-automatic-cutover no-rpo-rto-guarantee synthetic-host-admission-only]
      end
      def self.capture!(database:, dump:, output:, app_root:, configuration_files:, theme_root:, clock:, freeze_confirmed:)
        raise Error, "offline_freeze_required" unless freeze_confirmed == "writers-stopped-no-ddl"
        raise Error, "backup_path_exists" if File.exist?(dump) || File.exist?(output) || File.symlink?(dump) || File.symlink?(output)
        database.assert_restore_offline!
        before = database.integrity.capture
        source = database.instance_variable_get(:@config).database!.last
        site = database.query("SELECT install_id FROM sites").first
        raise Error, "backup_site" unless site
        objects = media(database)
        app = application(app_root, source["version"].start_with?("16.") ? "postgresql" : "mysql2")
        config = configuration(configuration_files)
        packages = themes(theme_root)
        observation = clock.sample
        database.dump!(SecureRandom.uuid, dump)
        database.assert_restore_offline!
        database.integrity.verify!(before)
        raise Error, "backup_dependency_changed" unless objects == media(database) && config == configuration(configuration_files) && packages == themes(theme_root) && app == application(app_root, before["engine"])
        document = { "format" => FORMAT, "id" => SecureRandom.uuid,
          "database" => { "engine" => before["engine"], "version" => source.fetch("version"), "source" => source,
            "dump_sha256" => Recovery.sha(dump), "dump_bytes" => File.size(dump), "integrity" => before },
          "application" => app, "site" => site,
          "consistency" => { "method" => "offline-before-dump-after-equal-v1", "observed_at" => Time.now.utc.iso8601,
            "clock_binding_sha256" => Digest::SHA256.hexdigest(observation["domain"] + observation["epoch"]) },
          "media" => objects, "configuration" => config, "themes" => packages,
          "security" => SECURITY.merge("password_verifiers_sha256" => Recovery.digest(database.query("SELECT id,password_digest FROM users ORDER BY id"))), "limitations" => limitations }
        validate!(document)
        bytes = Releases.canonical(document)
        raise Error, "manifest_limit" if bytes.bytesize > LIMIT
        F.atomic(output, bytes)
        document
      end
    end
  end
end
