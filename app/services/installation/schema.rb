# frozen_string_literal: true

require "tempfile"

module Installation
  module Schema
    class Refused < StandardError; end
    module_function

    def receipt_path(state) = File.join(state.root, "schema-receipt.json")

    def receipt(state)
      path = receipt_path(state)
      return nil unless File.exist?(path) || File.symlink?(path)
      stat = File.lstat(path)
      raise Refused, "Private schema receipt is unsafe." unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= 16_384
      value = JSON.parse(File.binread(path))
      raise Refused, "Private schema receipt requires operator review." unless value.is_a?(Hash) && value["format"] == 1 && %w[preparing ready review_required].include?(value["state"])
      value
    rescue JSON::ParserError
      raise Refused, "Private schema receipt requires operator review."
    end

    def versions
      Dir[Rails.root.join("db/migrate/[0-9]*_*.rb")].map { |path| File.basename(path).split("_").first }.sort
    end

    def source_digest
      Digest::SHA256.hexdigest(Dir[Rails.root.join("db/migrate/[0-9]*_*.rb")].sort.map { |path| "#{File.basename(path)}:#{Digest::SHA256.file(path).hexdigest}" }.join("\n"))
    end

    def ready?(state)
      saved = receipt(state)
      saved && saved["state"] == "ready" && saved["configuration"] == Configuration.fingerprint && saved["migrations"] == source_digest
    end

    def prepare!(state:, confirmation:)
      raise Refused, "Confirm the exact configured database fingerprint through the native operator command." unless ActiveSupport::SecurityUtils.secure_compare(confirmation.to_s, Configuration.fingerprint)
      raise Refused, "An installed instance cannot prepare its schema through setup." if state.installed?
      # The operator must establish the private root with setup-token before schema work.
      raise Refused, "Issue the private setup token first." unless File.directory?(state.root)
      lock_path = File.join(state.root, "schema.lock")
      if File.exist?(lock_path) || File.symlink?(lock_path)
        stat = File.lstat(lock_path)
        raise Refused, "Unsafe private schema lock." unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
      end
      state.with_uninstalled! do
      File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise Refused, "Another schema operation is active." unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        DatabaseProbe.call
        connection = ActiveRecord::Base.connection
        recorded = connection.table_exists?("schema_migrations") ? ActiveRecord::Base.connection_pool.schema_migration.versions : []
        raise Refused, "Unrecognized migration history requires operator review." unless (recorded - versions).empty?
        ensure_empty!(connection)
        write(state, "preparing")
        begin
          # Explicit operator action only: ordinary web boot never invokes this.
          ActiveRecord::Base.connection_pool.migration_context.migrate
          connection.schema_cache.clear!
          ensure_empty!(connection)
          raise Refused, "Migrations remain pending." unless (versions - ActiveRecord::Base.connection_pool.schema_migration.versions).empty?
          write(state, "ready")
        rescue StandardError
          write(state, "review_required")
          raise Refused, "Schema preparation stopped. Recorded completed migrations are retained; inspect partial DDL and repair forward before resuming. No table was dropped or rolled back.", cause: nil
        end
      ensure
        lock&.flock(File::LOCK_UN)
      end
      end
      receipt(state)
    end

    def ensure_empty!(connection)
      tables = connection.tables - %w[schema_migrations ar_internal_metadata]
      raise Refused, "Unrelated database tables are present." unless (tables - DatabaseProbe.allowed_tables).empty?
      connection.uncached do
        tables.each do |table|
          raise Refused, "Existing database rows require explicit operator review." if connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i.positive?
        end
      end
    end

    def write(state, status)
      value = { "format" => 1, "state" => status, "configuration" => Configuration.fingerprint, "migrations" => source_digest, "observed_at" => Time.current.utc.iso8601(6) }
      Tempfile.create([ "schema-receipt-", ".json" ], state.root) do |file|
        file.write(JSON.generate(value)); file.flush; file.fsync
        File.rename(file.path, receipt_path(state))
      end
      File.open(state.root, File::RDONLY, &:fsync)
    end
  end
end
