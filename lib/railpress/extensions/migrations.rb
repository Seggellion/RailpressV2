# frozen_string_literal: true

require "active_record/migration"
require "active_record/schema_migration"
require "active_record/internal_metadata"

module Railpress
  module Extensions
    module Migrations
      class SchemaMigration < ActiveRecord::SchemaMigration
        def initialize(pool, prefix)
          @prefix = prefix
          super(pool)
        end

        def table_name = "#{@prefix}_schema_migrations"
      end

      class InternalMetadata < ActiveRecord::InternalMetadata
        def initialize(pool, prefix)
          @prefix = prefix
          super(pool)
        end

        def table_name = "#{@prefix}_internal_metadata"
      end

      module_function

      # Invoked only by a native operator under the Core lifecycle lock.
      # Do not wrap the journal and DDL in one transaction: MySQL may commit DDL.
      def apply!(request:, registry:, lock_path:, admitted_lock: nil)
        operation = lambda do
          request.reload
          entry = registry.entries.fetch(request.module_id) { raise Invalid, "extension_migration_package" }
          validate_request!(request, registry, entry)
          migrate!(site: request.site, entry: entry)
        end
        if admitted_lock
          path = File.stat(lock_path)
          opened = admitted_lock.stat
          unless path.ino == opened.ino && path.dev == opened.dev && opened.uid == Process.uid &&
              (opened.mode & 0o077).zero? && admitted_lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Invalid, "extension_migration_lock"
          end
          operation.call
        else
          with_lifecycle_lock(lock_path, &operation)
        end
      end

      def applied?(site:, entry:)
        journal = ExtensionMigrationRecord.where(site: site, module_id: entry.id).index_by(&:version)
        return false unless journal.values.all? { |row| row.state == "applied" }
        versions = context(entry).get_all_versions.sort
        return false unless versions == journal.keys.map(&:to_i).sort
        entry.manifest.migrations.all? { |migration| journal[migration["version"]]&.sha256 == migration["sha256"] }
      end

      def context(entry)
        prefix = "rp_ext_#{Extensions.id!(entry.id).tr('-', '_')}"
        pool = ActiveRecord::Base.connection_pool
        ActiveRecord::MigrationContext.new([ File.join(entry.root, "db/migrate") ],
          SchemaMigration.new(pool, prefix), InternalMetadata.new(pool, prefix))
      end

      def validate_request!(request, registry, entry)
        system = registry.engine_set
        unless system && request.state == "migrating" && %w[install upgrade].include?(request.operation) &&
            request.site_identity == request.site.install_id && request.site_origin == request.site.canonical_origin &&
            request.site_identity == registry.site && request.core_version == Product::VERSION &&
            request.engine_generation == system.previous_generation && request.engine_fingerprint == system.previous_fingerprint &&
            request.version == entry.version && request.package_sha256 == entry.package_sha256 &&
            request.manifest_sha256 == entry.manifest.digest && request.plan_sha256 == entry.plan_sha256
          raise Invalid, "extension_migration_request"
        end
        ::Extensions::Requests.locked_owner!(request.actor_id, request.actor_auth_version)
      end

      def with_lifecycle_lock(path)
        raise Invalid, "extension_migration_lock" unless path.is_a?(String) && path.start_with?("/") && File.realpath(path) == path
        File.open(path, File::RDONLY | File::NOFOLLOW) do |lock|
          unless lock.stat.file? && lock.stat.uid == Process.uid && (lock.stat.mode & 0o077).zero? &&
              lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Invalid, "extension_migration_lock"
          end
          yield
        end
      rescue SystemCallError
        raise Invalid, "extension_migration_lock", cause: nil
      end

      def migrate!(site:, entry:)
        migrations = entry.manifest.migrations
        journal = ExtensionMigrationRecord.where(site: site, module_id: entry.id)
        existing = journal.index_by(&:version)
        migration_context = context(entry)
        versions = existing.keys.map(&:to_i).sort
        unless existing.values.all? { |row| row.state == "applied" } &&
            migration_context.get_all_versions.sort == versions &&
            (existing.keys - migrations.map { |row| row["version"] }).empty?
          raise Invalid, "extension_migration_recovery_required"
        end

        migrations.each do |migration|
          path = File.join(entry.root, migration["path"])
          file = entry.manifest.files.fetch(migration["path"])
          before = File.lstat(path)
          unless before.file? && !before.symlink? && before.size == file["size"] &&
              File.realpath(path) == path && Digest::SHA256.file(path).hexdigest == migration["sha256"]
            raise Invalid, "extension_migration_digest"
          end
          previous = existing[migration["version"]]
          raise Invalid, "extension_migration_digest" if previous && previous.sha256 != migration["sha256"]
          raise Invalid, "extension_migration_order" if !previous && versions.last && migration["version"].to_i <= versions.last
        end

        migrations.each do |migration|
          next if existing.key?(migration["version"])
          record = journal.create!(version: migration["version"], sha256: migration["sha256"], state: "started")
          begin
            migration_context.run(:up, record.version.to_i)
            record.update!(state: "applied")
          rescue StandardError
            record.update!(state: "recovery_required")
            raise Invalid, "extension_migration_recovery_required", cause: nil
          end
        end
      end
    end
  end
end
