# frozen_string_literal: true

module Railpress
  module NativeHost
    # A signed, state-bound repair of a single started final migration.
    class ModuleRepair
      ACTIONS = {
        "rerun_transactional" => [ "PostgreSQL", false ],
        "adopt_committed" => [ "PostgreSQL", true ],
        "record_implicit_commit" => [ "Mysql2", false ]
      }.freeze
      FIELDS = %w[action version migration_sha256 receipt_sequence before_sha256 after_schema_sha256 after_data_sha256].freeze
      MAX_ROWS = 10_000
      MAX_DATA_BYTES = 8 * 1024 * 1024

      def initialize(entry, connection: ActiveRecord::Base.connection)
        @entry = entry
        @db = connection
        @prefix = "rp_ext_#{Extensions.id!(entry.id).tr('-', '_')}_"
        @context = Extensions::Migrations.context(entry)
      end

      def observe(site)
        tables = @db.tables.select { |name| name.start_with?(@prefix) }.sort
        raise Error, "module_repair_inventory" if tables.empty? || tables.length > 32
        schemas = tables.to_h { |table| [ table, definition(table) ] }
        metadata_table = "#{@prefix}internal_metadata"
        records = tables.excluding("#{@prefix}schema_migrations", metadata_table).to_h { |table| [ table, table_data(table) ] }
        key, value = %w[key value].map { |column| @db.quote_column_name(column) }
        metadata = @db.select_rows("SELECT #{key},#{value} FROM #{@db.quote_table_name(metadata_table)} ORDER BY #{key}").to_h
        ledger = ExtensionMigrationRecord.where(site: site, module_id: @entry.id).order(:version).pluck(:version, :sha256, :state)
        { "schema_sha256" => Extensions.digest(schemas), "data_sha256" => Extensions.digest(records),
          "versions" => @context.get_all_versions.sort.map(&:to_s), "metadata" => metadata, "ledger" => ledger }
      end

      def apply!(request, plan)
        validate_plan!(plan)
        Site.transaction do
          site = Site.lock.find(request.site_id)
          request.lock!
          ::Extensions::Requests.locked_owner!(request.actor_id, request.actor_auth_version)
          unless request.operation == "install" && request.state == "awaiting_operator" &&
              request.receipt_sequence == plan["receipt_sequence"] && request.site_identity == site.install_id &&
              request.site_origin == site.canonical_origin && @entry.id == request.module_id &&
              [ @entry.package_sha256, @entry.manifest.digest, @entry.plan_sha256 ] ==
                request.attributes.values_at("package_sha256", "manifest_sha256", "plan_sha256") &&
              !ExtensionInstallation.exists?(site: site, module_id: request.module_id)
            raise Error, "module_repair_request"
          end
          validate_migrations!(plan)
          before = observe(site)
          versions = expected_versions!(before, plan)
          raise Error, "module_repair_precondition" unless Extensions.digest(before) == plan["before_sha256"]
          version = versions.last
          case plan["action"]
          when "rerun_transactional"
            raise Error, "module_repair_transaction" unless @db.supports_ddl_transactions?
            @context.run(:up, version.to_i)
          when "record_implicit_commit"
            assert_innodb!
            @context.schema_migration.create_version(version)
          end
          physical = observe(site)
          metadata = before.fetch("metadata")
          metadata = metadata.merge("environment" => @db.pool.db_config.env_name) if plan["action"] == "rerun_transactional"
          unless physical["versions"] == versions && physical["metadata"] == metadata && physical.values_at("schema_sha256", "data_sha256") ==
              plan.values_at("after_schema_sha256", "after_data_sha256")
            raise Error, "module_repair_postcondition"
          end
          record = ExtensionMigrationRecord.lock.find_by!(site: site, module_id: @entry.id, version: version)
          raise Error, "module_repair_ledger" unless record.state == "started" && record.sha256 == plan["migration_sha256"]
          record.update!(state: "applied")
          raise Error, "module_repair_ledger" unless Extensions::Migrations.applied?(site: site, entry: @entry)
          { "action" => plan["action"], "before" => before, "after" => observe(site) }
        end
      end

      private

      def validate_plan!(plan)
        Releases.keys!(plan, FIELDS)
        unless ACTIONS.key?(plan["action"]) && ACTIONS.fetch(plan["action"]).first == @db.adapter_name
          raise Error, "module_repair_action"
        end
        %w[migration_sha256 before_sha256 after_schema_sha256 after_data_sha256].each { |key| Releases.identity!(plan[key]) }
        Extensions.generation!(plan["receipt_sequence"])
      end

      def validate_migrations!(plan)
        migrations = @entry.manifest.migrations
        unless migrations.last&.values_at("version", "sha256") == plan.values_at("version", "migration_sha256")
          raise Error, "module_repair_migration"
        end
        migrations.each do |row|
          path = File.join(@entry.root, row.fetch("path"))
          expected = @entry.manifest.files.fetch(row.fetch("path"))
          unless File.realpath(path) == path && Digest::SHA256.hexdigest(F.read(path, maximum: expected.fetch("size"))) == row["sha256"]
            raise Error, "module_repair_migration"
          end
        end
      end

      def expected_versions!(before, plan)
        expected = @entry.manifest.migrations.map do |row|
          [ row["version"], row["sha256"], row["version"] == plan["version"] ? "started" : "applied" ]
        end
        versions = expected.map(&:first)
        stamped = ACTIONS.fetch(plan["action"]).last
        unless before["ledger"] == expected && before["versions"] == (stamped ? versions : versions.first(versions.length - 1))
          raise Error, "module_repair_ledger"
        end
        if plan["action"] != "rerun_transactional" && before.values_at("schema_sha256", "data_sha256") !=
            plan.values_at("after_schema_sha256", "after_data_sha256")
          raise Error, "module_repair_postcondition"
        end
        versions
      end

      def definition(table)
        if @db.adapter_name == "PostgreSQL"
          relation = "to_regclass(#{@db.quote("public.#{table}")})"
          {
            "table" => @db.select_rows("SELECT relkind, relpersistence, reloptions, relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid=#{relation}"),
            "columns" => @db.select_rows("SELECT a.attname, format_type(a.atttypid,a.atttypmod), a.attnotnull, pg_get_expr(d.adbin,d.adrelid), a.attidentity, a.attgenerated, c.collname FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum LEFT JOIN pg_collation c ON c.oid=a.attcollation WHERE a.attrelid=#{relation} AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum"),
            "constraints" => @db.select_rows("SELECT conname, pg_get_constraintdef(oid), convalidated FROM pg_constraint WHERE conrelid=#{relation} OR confrelid=#{relation} ORDER BY conname,conrelid::regclass::text"),
            "indexes" => @db.select_rows("SELECT pg_get_indexdef(indexrelid), indisvalid FROM pg_index WHERE indrelid=#{relation} ORDER BY indexrelid::regclass::text"),
            "triggers" => @db.select_rows("SELECT pg_get_triggerdef(oid), tgenabled FROM pg_trigger WHERE tgrelid=#{relation} AND NOT tgisinternal ORDER BY tgname"),
            "sequences" => @db.select_rows("SELECT sequence.relname,s.seqtypid::regtype::text,s.seqstart,s.seqincrement,s.seqmax,s.seqmin,s.seqcache,s.seqcycle FROM pg_depend d JOIN pg_class sequence ON sequence.oid=d.objid JOIN pg_sequence s ON s.seqrelid=sequence.oid WHERE d.refobjid=#{relation} AND d.deptype IN ('a','i') ORDER BY sequence.relname")
          }
        else
          [ @db.select_rows("SHOW CREATE TABLE #{@db.quote_table_name(table)}").sole,
            @db.select_rows("SELECT TRIGGER_NAME, EVENT_MANIPULATION, ACTION_TIMING, ACTION_STATEMENT, SQL_MODE FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=DATABASE() AND EVENT_OBJECT_TABLE=#{@db.quote(table)} ORDER BY TRIGGER_NAME") ]
        end
      end

      def table_data(table)
        rows = @db.select_rows("SELECT * FROM #{@db.quote_table_name(table)} LIMIT #{MAX_ROWS + 1}")
        raise Error, "module_repair_data_capacity" if rows.length > MAX_ROWS
        bytes = 0
        digests = rows.map do |row|
          encoded = row.map { |value| value.nil? ? nil : Base64.strict_encode64(value.to_s.b) }
          bytes += encoded.compact.sum(&:bytesize)
          raise Error, "module_repair_data_capacity" if bytes > MAX_DATA_BYTES
          Extensions.digest(encoded)
        end
        { "count" => rows.length, "sha256" => Extensions.digest(digests.sort) }
      end

      def assert_innodb!
        tables = [ "extension_migration_records", "#{@prefix}schema_migrations" ]
        names = tables.map { |name| @db.quote(name) }.join(",")
        engines = @db.select_values("SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN (#{names})")
        raise Error, "module_repair_transaction" unless engines == [ "InnoDB", "InnoDB" ]
      end
    end
  end
end
