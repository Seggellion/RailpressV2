# frozen_string_literal: true

require "active_support/inflector"

module Railpress
  module NativeHost
    # Signed, private recovery evidence; never a public export or database repair.
    class DatabaseIntegrity
      FORMAT = "railpress.database-integrity.v1"
      MAX_ROWS = 100_000
      MAX_BYTES = 64 * 1024 * 1024
      REVOKED = %w[user_sessions password_resets content_previews theme_previews navigation_previews].freeze
      class SchemaMismatch < Error
        attr_reader :definitions
        def initialize(expected, actual)
          super("restored_database_schema_integrity")
          @definitions = { "expected" => expected, "actual" => actual }
        end
      end
      def initialize(database, engine, extra_tables: [], strict_core: true)
        @database, @engine = database, engine
        @extra_tables, @strict_core = extra_tables, strict_core
      end
      def query(sql)
        (@engine == "postgresql" ? @client.exec(sql) : @client.query(sql, cast: false)).to_a
      end
      def identifier(name) = @database.quote_identifier(name)
      def digest(value) = Digest::SHA256.hexdigest(Releases.canonical(value))
      def source
        File.read(File.expand_path("../../../db/schema_#{@engine}.rb", __dir__))
      end
      def expected_keys
        source.lines.filter_map do |line|
          next unless line.lstrip.start_with?("add_foreign_key ")
          match = /\A\s*add_foreign_key "([a-z0-9_]+)", "([a-z0-9_]+)"(.*)\n?\z/.match(line)
          raise Error, "integrity_schema_definition" unless match
          from, to, options = match.captures
          columns = options[/, column: (\[[^\]]+\]|"[^"]+")/, 1]
          primary = options[/, primary_key: (\[[^\]]+\]|"[^"]+")/, 1]
          deletion = options[/, on_delete: :(cascade|nullify|restrict)/, 1] || "restrict"
          columns = columns ? Array(JSON.parse(columns)) : [ "#{to.singularize}_id" ]
          primary = primary ? Array(JSON.parse(primary)) : [ "id" ]
          [ from, to, columns, primary, deletion ]
        end.sort
      end
      def foreign_keys
        if @engine == "postgresql"
          raise Error, "integrity_foreign_key_enforcement" unless query("SHOW session_replication_role").first.values.first == "origin"
          disabled = query("SELECT COUNT(*) AS n FROM pg_constraint c WHERE c.contype='f' AND c.connamespace='public'::regnamespace AND (NOT c.convalidated OR EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgconstraint=c.oid AND t.tgenabled<>'O'))").first["n"].to_i
          raise Error, "integrity_foreign_key_enforcement" unless disabled.zero?
          rows = query("SELECT c.conname AS name, f.relname AS source, p.relname AS target, a.attname AS column_name, b.attname AS primary_key, c.confdeltype AS deletion FROM pg_constraint c JOIN pg_class f ON f.oid=c.conrelid JOIN pg_class p ON p.oid=c.confrelid CROSS JOIN LATERAL unnest(c.conkey,c.confkey) WITH ORDINALITY AS keys(source_key,target_key,position) JOIN pg_attribute a ON a.attrelid=f.oid AND a.attnum=keys.source_key JOIN pg_attribute b ON b.attrelid=p.oid AND b.attnum=keys.target_key WHERE c.contype='f' AND c.connamespace='public'::regnamespace ORDER BY c.conname,keys.position")
          deletion = { "a" => "restrict", "r" => "restrict", "c" => "cascade", "n" => "nullify" }
        else
          raise Error, "integrity_foreign_key_enforcement" unless query("SELECT @@SESSION.foreign_key_checks AS n").first["n"].to_i == 1
          rows = query("SELECT k.CONSTRAINT_NAME AS name,k.TABLE_NAME AS source,k.REFERENCED_TABLE_NAME AS target,k.COLUMN_NAME AS column_name,k.REFERENCED_COLUMN_NAME AS primary_key,r.DELETE_RULE AS deletion FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_SCHEMA=k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME=k.CONSTRAINT_NAME AND r.TABLE_NAME=k.TABLE_NAME WHERE k.CONSTRAINT_SCHEMA=DATABASE() AND k.REFERENCED_TABLE_NAME IS NOT NULL ORDER BY k.CONSTRAINT_NAME,k.ORDINAL_POSITION")
          deletion = { "NO ACTION" => "restrict", "RESTRICT" => "restrict", "CASCADE" => "cascade", "SET NULL" => "nullify" }
        end
        rows.group_by { |row| [ row.fetch("source"), row.fetch("name") ] }.values.map do |group|
          row = group.first
          [ row.fetch("source"), row.fetch("target"), group.map { |part| part.fetch("column_name") }, group.map { |part| part.fetch("primary_key") }, deletion.fetch(row.fetch("deletion")) ]
        end.sort
      end
      def normalize_check(definition)
        # pg_dump can move an unbounded varchar -> text coercion from the
        # ARRAY expression to each literal. Preserve every literal and predicate.
        definition.gsub(/ARRAY\[((?:'(?:[^']|'')*'(?:::character varying(?:::text)?|::text)?(?:,\s*)?)+)\](?:::text\[\])?/) do
          values = Regexp.last_match(1).scan(/'(?:[^']|'')*'/)
          "ARRAY[#{values.map { |value| "#{value}::text" }.join(', ')}]"
        end
      end
      def schema
        tables = if @engine == "postgresql"
          query("SELECT tablename AS name FROM pg_tables WHERE schemaname='public'").map { |row| row["name"] }.sort
        else
          query("SHOW TABLES").map { |row| row.values.first }.sort
        end
        expected = (source.scan(/^\s*create_table "([a-z0-9_]+)"/).flatten + %w[ar_internal_metadata schema_migrations]).sort
        if @strict_core && tables != (expected + @extra_tables).sort.uniq
          raise Error, "integrity_table_inventory"
        end
        keys = foreign_keys
        if @strict_core && keys.reject { |row| @extra_tables.include?(row.first) } != expected_keys
          raise Error, "integrity_foreign_key_inventory"
        end
        keys.each do |from, to, columns, primary, _deletion|
          (columns + primary).each { |name| identifier(name) }
          join = columns.zip(primary).map { |left, right| "f.#{identifier(left)}=p.#{identifier(right)}" }.join(" AND ")
          present = columns.map { |name| "f.#{identifier(name)} IS NOT NULL" }.join(" AND ")
          orphan = query("SELECT 1 AS orphan FROM #{identifier(from)} f LEFT JOIN #{identifier(to)} p ON #{join} WHERE #{present} AND p.#{identifier(primary.first)} IS NULL LIMIT 1")
          raise Error, "integrity_orphan_record" if orphan.any?
        end
        scope = @engine == "postgresql" ? "table_schema='public'" : "table_schema=DATABASE()"
        columns = query("SELECT table_name,column_name,data_type,is_nullable,column_default,ordinal_position FROM information_schema.columns WHERE #{scope} ORDER BY table_name,ordinal_position")
        if @engine == "postgresql"
          indexes = query("SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY tablename,indexname")
          checks = query("SELECT t.relname AS table_name,c.conname,pg_get_constraintdef(c.oid,true) AS definition FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE c.connamespace='public'::regnamespace AND c.contype IN ('c','p','u') ORDER BY t.relname,c.conname")
          checks.each { |row| row["definition"] = normalize_check(row.fetch("definition")) }
        else
          indexes = query("SELECT TABLE_NAME,INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,SUB_PART,COLLATION,INDEX_TYPE FROM information_schema.statistics WHERE table_schema=DATABASE() ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX")
          checks = query("SELECT t.TABLE_NAME,t.CONSTRAINT_NAME,c.CHECK_CLAUSE FROM information_schema.TABLE_CONSTRAINTS t JOIN information_schema.CHECK_CONSTRAINTS c ON c.CONSTRAINT_SCHEMA=t.CONSTRAINT_SCHEMA AND c.CONSTRAINT_NAME=t.CONSTRAINT_NAME WHERE t.CONSTRAINT_SCHEMA=DATABASE() ORDER BY t.TABLE_NAME,t.CONSTRAINT_NAME")
        end
        { "tables" => tables, "foreign_keys" => keys, "columns" => columns, "indexes" => indexes, "checks" => checks }
      end
      def verify_schema!
        @database.connection do |client, _engine|
          @client = client
          schema
        end
        true
      ensure
        @client = nil
      end
      def schema_fingerprint
        @database.connection do |client, _engine|
          @client = client
          digest({ "definition" => schema, "versions" => query("SELECT version FROM schema_migrations ORDER BY version").map { |row| row.fetch("version") } })
        end
      ensure
        @client = nil
      end
      def normalized(row)
        row.transform_values { |value| value.nil? ? nil : Base64.strict_encode64(value.to_s.b) }
      end
      def records(rows)
        { "count" => rows.length, "sha256" => digest(rows.map { |row| digest(normalized(row)) }.sort) }
      end
      def capture
        @database.connection do |client, _engine|
          @client = client
          definition = schema
          before, after, bytes = {}, {}, 0
          definition.fetch("tables").each do |table|
            rows = query("SELECT * FROM #{identifier(table)} LIMIT #{MAX_ROWS + 1}")
            raise Error, "integrity_record_limit" if rows.length > MAX_ROWS
            bytes += rows.sum { |row| Releases.canonical(normalized(row)).bytesize }
            raise Error, "integrity_record_limit" if bytes > MAX_BYTES
            before[table] = records(rows)
            expected = if REVOKED.include?(table)
              []
            elsif table == "users"
              rows.map { |row| row.merge("auth_version" => row.fetch("auth_version").to_i + 1) }
            elsif table == "media_references"
              rows.select { |row| row["content_preview_id"].nil? }
            else
              rows
            end
            after[table] = records(expected)
          end
          { "format" => FORMAT, "engine" => @engine, "schema_sha256" => digest(definition), "schema" => definition, "before" => before, "after_revocation" => after }
        end
      ensure
        @client = nil
      end
      def validate!(expected)
        raise Error, "snapshot_database_evidence_missing" unless expected.is_a?(Hash)
        Releases.keys!(expected, %w[format engine schema_sha256 schema before after_revocation])
        raise Error, "snapshot_database_evidence" unless expected["format"] == FORMAT && expected["engine"] == @engine
        Releases.identity!(expected["schema_sha256"])
        Releases.keys!(expected["schema"], %w[tables foreign_keys columns indexes checks])
        raise Error, "snapshot_database_evidence" unless digest(expected["schema"]) == expected["schema_sha256"]
        %w[before after_revocation].each do |phase|
          rows = expected[phase]
          raise Error, "snapshot_database_evidence" unless rows.is_a?(Hash) && rows.length.between?(1, 100)
          rows.each do |table, row|
            identifier(table)
            Releases.keys!(row, %w[count sha256])
            Releases.integer!(row["count"], 0, MAX_ROWS)
            Releases.identity!(row["sha256"])
          end
        end
        raise Error, "snapshot_database_evidence" unless expected["before"].keys.sort == expected["after_revocation"].keys.sort
        expected
      end
      def verify!(expected, revoked: false)
        validate!(expected)
        actual = capture
        phase = revoked ? "after_revocation" : "before"
        raise SchemaMismatch.new(expected["schema"], actual["schema"]) unless actual["schema_sha256"] == expected["schema_sha256"]
        raise Error, "restored_database_record_integrity" unless actual["before"] == expected[phase]
        true
      end
    end
  end
end
