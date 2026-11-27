# frozen_string_literal: true

module Railpress
  module NativeHost
    class Schema
      TYPES = { "string" => "VARCHAR(255)", "text" => "TEXT", "integer" => "INTEGER", "bigint" => "BIGINT", "json" => "JSON" }.freeze
      def initialize(config)
        @config = config
        @db = Database.new(config)
      end
      def validate!(plan)
        return validate_files!(plan) if plan.is_a?(Hash) && plan["format"] == "railpress.expand.files.v1"
        Releases.keys!(plan, %w[format migration_version schema_from schema_to write_contract jobs_read jobs_write steps])
        raise Error, "expand_plan_format" unless plan["format"] == "railpress.expand.v1"
        raise Error, "migration_identity" unless plan["migration_version"].is_a?(String) && plan["migration_version"].match?(/\A\d{14}\z/)
        %w[schema_from schema_to write_contract].each { |key| Releases.integer!(plan[key], 1, 100_000) }
        raise Error, "schema_contraction_forbidden" unless plan["schema_to"] >= plan["schema_from"]
        %w[jobs_read jobs_write].each do |key|
          range = plan[key]
          raise Error, "job_window" unless range.is_a?(Array) && range.length == 2 &&
            range.all? { |v| v.is_a?(Integer) && v.between?(1, 100_000) } && range.first <= range.last
        end
        raise Error, "expand_steps" unless plan["steps"].is_a?(Array) && plan["steps"].length <= 16
        plan["steps"].each do |step|
          kind = step["kind"]
          keys = kind == "add_nullable_column" ? %w[kind table column type] : %w[kind table column source batch]
          Releases.keys!(step, keys)
          raise Error, "expand_operation" unless %w[add_nullable_column backfill_copy].include?(kind)
          %w[table column].each { |key| @db.quote_identifier(step[key]) }
          raise Error, "protected_schema" unless %w[contents content_revisions media_assets menus menu_items terms taxonomies sites].include?(step["table"])
          raise Error, "expand_column" unless step["column"].start_with?("extension_")
          if kind == "add_nullable_column"
            raise Error, "expand_type" unless TYPES.key?(step["type"])
          else
            @db.quote_identifier(step["source"])
            raise Error, "backfill_source" unless %w[title excerpt slug name label].include?(step["source"])
            Releases.integer!(step["batch"], 1, 1000)
          end
        end
        plan
      end
      def validate_files!(plan)
        Releases.keys!(plan, %w[format engine site predecessor release schema_from schema_to write_contract jobs_read jobs_write before after migrations])
        unless plan["format"] == "railpress.expand.files.v1" && plan["engine"] == @config.data["engine"] &&
            plan["site"] == @config.data["install_id"]
          raise Error, "native_expand_binding"
        end
        %w[predecessor release before after].each { |field| Releases.identity!(plan[field]) }
        %w[schema_from schema_to write_contract].each { |field| Releases.integer!(plan[field], 1, 100_000) }
        raise Error, "schema_contraction_forbidden" unless plan["schema_to"] > plan["schema_from"] && plan["write_contract"] == plan["schema_to"]
        %w[jobs_read jobs_write].each { |field| Releases::PackageContext.number_window!(plan[field]) }
        rows = plan.fetch("migrations")
        raise Error, "native_migration_inventory" unless rows.is_a?(Array) && rows.size.between?(1, 8)
        rows.each do |row|
          Releases.keys!(row, %w[version path sha256])
          unless row["version"].is_a?(String) && row["version"].match?(/\A[1-9]\d{13}\z/) &&
              row["path"].is_a?(String) && row["path"].match?(%r{\Adb/migrate/#{row['version']}_[a-z][a-z0-9_]*\.rb\z})
            raise Error, "native_migration_identity"
          end
          Releases.identity!(row["sha256"])
        end
        versions = rows.map { |row| row["version"] }
        raise Error, "native_migration_order" unless versions == versions.uniq.sort
        plan
      end

      def file_plan?(plan) = plan && plan["format"] == "railpress.expand.files.v1"

      def apply_files!(plan, manifest:, candidate:, predecessor:, request_id:, environment:, progress:, previous_progress: nil, fault: nil)
        validate_files!(plan)
        NativeHost.uuid!(request_id)
        raise Error, "native_expand_binding" unless plan.values_at("release", "predecessor") == [ candidate, predecessor ]
        raise Error, "native_migration_reconciliation_required" if previous_progress
        raise Error, "native_migration_profile" unless @config.data["scope"] == "isolated-synthetic-nginx-v1" &&
          @config.data["test_database_profile"] == "w03_bridge"
        @db.assert_installation!
        @db.assert_restore_offline!
        definition = @db.integrity(strict_core: false)
        raise Error, "native_schema_predecessor" unless definition.schema_fingerprint == plan["before"]
        root = @config.release(candidate)
        rows = plan["migrations"]
        versions = @db.query("SELECT version FROM schema_migrations").map { |row| row["version"] }
        candidates = manifest.fetch("files").keys.grep(%r{\Adb/migrate/[0-9]{14}_[a-z0-9_]+\.rb\z})
        pending = candidates.reject { |name| versions.include?(File.basename(name).split("_").first) }.sort
        raise Error, "native_migration_pending" unless pending == rows.map { |row| row["path"] }
        rows.each do |row|
          entry = manifest.fetch("files").fetch(row["path"])
          bytes = F.read(File.join(root, row["path"]), maximum: 131_072)
          unless entry["sha256"] == row["sha256"] && Digest::SHA256.hexdigest(bytes) == row["sha256"]
            raise Error, "native_migration_digest"
          end
        end
        progress.call({ "state" => "STARTED", "completed_versions" => [], "partial" => true })
        completed = []
        rows.each do |row|
          fault&.call("before_file_migration")
          log = @config.path("logs", "migration-#{request_id}-#{row['version']}.log")
          launcher = File.expand_path("../../../bin/railpress-native-migrate", __dir__)
          Commands.run([ @config.data["ruby_binary"], launcher, *row.values_at("version", "path", "sha256") ],
            env: environment, chdir: root, log: log)
          fault&.call("after_file_migration")
          completed << row["version"]
          progress.call({ "state" => "STARTED", "completed_versions" => completed.dup, "partial" => true })
        end
        @db.assert_restore_offline!
        raise Error, "native_schema_candidate" unless definition.schema_fingerprint == plan["after"]
        report = { "state" => "APPLIED", "completed_versions" => completed, "partial" => false, "schema_sha256" => plan["after"] }
        progress.call(report)
        report
      end
      def apply!(plan, progress:, fault: nil)
        validate!(plan)
        @db.assert_installation!
        version = plan["migration_version"]
        applied = @db.query("SELECT version FROM schema_migrations WHERE version='#{version}'")
        # Old compatible writers can create rows with NULL extension columns.
        # Rechecking the signed idempotent backfill is required even after its stamp.
        plan["steps"].each { |step| verify_step!(step) } if applied.any?
        if applied.any? && plan["steps"].select { |step| step["kind"] == "backfill_copy" }.all? { |step|
            table, column, source = %w[table column source].map { |key| @db.quote_identifier(step[key]) }
            @db.query("SELECT id FROM #{table} WHERE #{column} IS NULL AND #{source} IS NOT NULL LIMIT 1").empty?
          }
          return { "already_applied" => true, "steps" => plan["steps"].length, "partial" => false }
        end
        count = 0
        plan["steps"].each do |step|
          table, column = %w[table column].map { |key| @db.quote_identifier(step[key]) }
          if step["kind"] == "add_nullable_column"
            @db.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{TYPES.fetch(step['type'])} NULL") unless @db.column?(step["table"], step["column"])
            verify_step!(step)
          else
            source = @db.quote_identifier(step["source"])
            loop do
              ids = @db.query("SELECT id FROM #{table} WHERE #{column} IS NULL AND #{source} IS NOT NULL ORDER BY id LIMIT #{step['batch']}").map { |row| Integer(row["id"]) }
              break if ids.empty?
              @db.execute("UPDATE #{table} SET #{column}=#{source} WHERE id IN (#{ids.join(',')}) AND #{column} IS NULL")
              progress.call({ "step" => count, "last_id" => ids.last, "partial" => true })
              fault&.call("backfill_batch")
            end
          end
          count += 1
          progress.call({ "steps_completed" => count, "partial" => true })
          fault&.call("schema_step")
        end
        @db.execute("INSERT INTO schema_migrations(version) VALUES('#{version}')") if applied.empty?
        { "steps" => count, "already_applied" => applied.any?, "partial" => false }
      end
      def verify_step!(step, complete: false)
        metadata = @db.column_metadata(step["table"], step["column"])
        raise Error, "expand_column_missing" unless metadata
        if step["kind"] == "add_nullable_column"
          types = { "string" => [ "character varying", "varchar" ], "text" => [ "text" ], "integer" => [ "integer", "int" ], "bigint" => [ "bigint" ], "json" => [ "json" ] }
          raise Error, "partial_schema_mismatch" unless types.fetch(step["type"]).include?(metadata["data_type"]) && metadata["is_nullable"] == "YES"
        elsif complete
          table, column, source = %w[table column source].map { |key| @db.quote_identifier(step[key]) }
          raise Error, "backfill_incomplete" if @db.query("SELECT id FROM #{table} WHERE #{column} IS NULL AND #{source} IS NOT NULL LIMIT 1").any?
        end
      end
      def revert_eligible!(manifest, contract)
        tables = @db.table_names
        if tables.include?("extension_installations")
          rows = @db.query("SELECT id FROM extension_installations LIMIT 1")
          schema2 = @db.column?("theme_installations", "upload_publisher") &&
            @db.query("SELECT id FROM theme_installations WHERE upload_publisher IS NOT NULL LIMIT 1").any?
          jobs = @db.query("SELECT id FROM solid_queue_jobs WHERE finished_at IS NULL AND class_name='ValidateThemeUploadJob' LIMIT 1")
          unless (rows.empty? && !schema2 && jobs.empty?) || manifest.fetch("files", {}).key?("lib/railpress/releases/package_context.rb")
            raise Error, "incompatible_revert_packages"
          end
        end
        unless manifest.fetch("files", {}).key?("lib/railpress/extensions/candidate_withdrawals.rb")
          if tables.include?("platform_states") && @db.query("SELECT id FROM platform_states WHERE scope_name LIKE 'extension!_candidate!_withdrawal:%' ESCAPE '!' LIMIT 1").any?
            raise Error, "incompatible_revert_candidate_withdrawals"
          end
        end
        if tables.include?("import_batches")
          required_state = @db.query("SELECT id FROM import_batches LIMIT 1").any? || @db.query("SELECT id FROM portability_exports LIMIT 1").any? || @db.query("SELECT id FROM portability_identities LIMIT 1").any?
          pending = @db.query("SELECT id FROM solid_queue_jobs WHERE finished_at IS NULL AND class_name IN ('PortabilityExportJob','PortabilityImportJob') LIMIT 1").any?
          required = %w[lib/railpress/portability_contract.rb app/jobs/portability_export_job.rb app/jobs/portability_import_job.rb app/services/portability/worker.rb]
          raise Error, "incompatible_revert_portability" if (required_state || pending) && !required.all? { |path| manifest.fetch("files", {}).key?(path) }
        end
        if tables.include?("contents") && page_paths_required?
          raise Error, "incompatible_revert_page_paths" unless manifest.fetch("files", {}).key?("lib/railpress/page_path_contract.rb")
        end
        if tables.include?("official_news_states")
          enabled = @db.query("SELECT id FROM official_news_states WHERE enabled=TRUE OR provider_enabled=TRUE").any?
          pending = @db.query("SELECT id FROM solid_queue_jobs WHERE finished_at IS NULL AND class_name IN ('OfficialNewsRefreshJob','OfficialNewsSweepJob')").any?
          if enabled || pending
            required = %w[app/jobs/official_news_refresh_job.rb app/jobs/official_news_sweep_job.rb app/services/official_news/refresh.rb]
            raise Error, "incompatible_revert_official_news" unless required.all? { |path| manifest.fetch("files", {}).key?(path) }
          end
        end
        c = manifest.fetch("compatibility")
        { "schema_read" => contract.fetch("schema"), "schema_write" => contract.fetch("write"),
          "jobs_read" => contract.fetch("jobs"), "jobs_write" => contract.fetch("jobs") }.each do |key, actual|
          raise Error, "incompatible_revert_#{key}" unless (c.fetch(key).first..c.fetch(key).last).cover?(actual)
        end
        raise Error, "incompatible_revert_security" unless c["security_clock"] == 2
        raise Error, "incompatible_revert_theme" unless c["theme_api"] == contract.fetch("theme_api")
        true
      end
      # Includes private working data and retained revisions, not only today's
      # public URLs. Older writers could otherwise flatten a restored Page path.
      def page_paths_required?
        return true if @db.query("SELECT id FROM contents WHERE type='Page' AND (slug LIKE '%/%' OR last_public_path LIKE '/%/%') LIMIT 1").any?
        return true if @db.query("SELECT id FROM redirects WHERE source_path LIKE '/%/%' AND source_path NOT LIKE '/blog/%' LIMIT 1").any?
        after = 0
        100.times do
          rows = @db.query("SELECT r.id, r.snapshot FROM content_revisions r JOIN contents c ON c.id=r.content_id WHERE c.type='Page' AND r.id>#{after} ORDER BY r.id LIMIT 100")
          return false if rows.empty?
          return true if rows.any? { |row|
            value = row["snapshot"].is_a?(String) ? JSON.parse(row["snapshot"]) : row["snapshot"]
            !value.is_a?(Hash) || value["slug"].to_s.include?("/")
          }
          after = Integer(rows.last["id"])
        end
        true # Unknown larger history requires the new reader conservatively.
      rescue JSON::ParserError, TypeError, ArgumentError
        true
      end
    end
  end
end
