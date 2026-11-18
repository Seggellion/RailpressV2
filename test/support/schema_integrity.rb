# Test-only guard: a failed native restore must not contaminate subsequent cases.
module TestSchemaIntegrity
  class Unsafe < StandardError; end
  module_function

  def expected(engine)
    Rails.root.join("db/schema_#{engine}.rb").read.lines.filter_map do |line|
      next unless line.lstrip.start_with?("add_foreign_key ")
      match = /\A\s*add_foreign_key "([a-z0-9_]+)", "([a-z0-9_]+)"(.*)\n?\z/.match(line)
      raise Unsafe, "unsupported schema foreign key" unless match
      from, to, options = match.captures
      column_text = options[/, column: (\[[^\]]+\]|"[^"]+")/, 1]
      primary_text = options[/, primary_key: (\[[^\]]+\]|"[^"]+")/, 1]
      columns = column_text ? Array(JSON.parse(column_text)) : [ "#{to.singularize}_id" ]
      primary = primary_text ? Array(JSON.parse(primary_text)) : [ "id" ]
      raise Unsafe, "unsupported schema foreign key identifiers" unless (columns + primary).all? { |name| /\A[a-z0-9_]+\z/.match?(name) }
      deletion = options[/, on_delete: :(cascade|nullify|restrict)/, 1] || "restrict"
      remainder = options.sub(/, column: (\[[^\]]+\]|"[^"]+")/, "").sub(/, primary_key: (\[[^\]]+\]|"[^"]+")/, "").sub(/, name: "[a-z0-9_]+"/, "").sub(/, on_delete: :(cascade|nullify|restrict)/, "")
      raise Unsafe, "unsupported schema foreign key options" unless remainder.strip.empty?
      [ from, to, columns, primary, deletion ]
    end.sort
  end

  def actual(connection, engine)
    if engine == "postgresql"
      raise Unsafe, "foreign key enforcement disabled" unless connection.select_value("SHOW session_replication_role") == "origin"
      disabled = connection.select_value("SELECT COUNT(*) FROM pg_constraint c WHERE c.contype='f' AND c.connamespace='public'::regnamespace AND (NOT c.convalidated OR EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgconstraint=c.oid AND t.tgenabled<>'O'))").to_i
      raise Unsafe, "unvalidated or disabled foreign key" unless disabled.zero?
      sql = "SELECT c.conname AS constraint_name, f.relname AS source, p.relname AS target, a.attname AS column_name, b.attname AS primary_key, c.confdeltype AS deletion FROM pg_constraint c JOIN pg_class f ON f.oid=c.conrelid JOIN pg_class p ON p.oid=c.confrelid CROSS JOIN LATERAL unnest(c.conkey,c.confkey) WITH ORDINALITY AS keys(source_key,target_key,position) JOIN pg_attribute a ON a.attrelid=f.oid AND a.attnum=keys.source_key JOIN pg_attribute b ON b.attrelid=p.oid AND b.attnum=keys.target_key WHERE c.contype='f' AND c.connamespace='public'::regnamespace ORDER BY c.conname,keys.position"
      deletion = { "a" => "restrict", "r" => "restrict", "c" => "cascade", "n" => "nullify" }
    else
      raise Unsafe, "foreign key enforcement disabled" unless connection.select_value("SELECT @@SESSION.foreign_key_checks").to_i == 1
      sql = "SELECT k.CONSTRAINT_NAME AS constraint_name, k.TABLE_NAME AS source, k.REFERENCED_TABLE_NAME AS target, k.COLUMN_NAME AS column_name, k.REFERENCED_COLUMN_NAME AS primary_key, r.DELETE_RULE AS deletion FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_SCHEMA=k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME=k.CONSTRAINT_NAME AND r.TABLE_NAME=k.TABLE_NAME WHERE k.CONSTRAINT_SCHEMA=DATABASE() AND k.REFERENCED_TABLE_NAME IS NOT NULL ORDER BY k.CONSTRAINT_NAME,k.ORDINAL_POSITION"
      deletion = { "NO ACTION" => "restrict", "RESTRICT" => "restrict", "CASCADE" => "cascade", "SET NULL" => "nullify" }
    end
    connection.select_all(sql).group_by { |row| [ row.fetch("source"), row.fetch("constraint_name") ] }.values.map do |rows|
      row = rows.first
      [ row.fetch("source"), row.fetch("target"), rows.map { |part| part.fetch("column_name") }, rows.map { |part| part.fetch("primary_key") }, deletion.fetch(row.fetch("deletion")) ]
    end.sort
  end

  def verify!
    unsafe = Rails.root.join(".local/state/m12-tests").glob("host-*/run/mysql-restore-unsafe.json")
    raise Unsafe, "native restore session not verified quiescent; retain fixture" if unsafe.any?
    engine = ENV.fetch("RAILPRESS_TEST_ENGINE")
    wanted = expected(engine)
    connection = ActiveRecord::Base.connection
    observed = connection.uncached do
      tables = Rails.root.join("db/schema_#{engine}.rb").read.scan(/^\s*create_table "([a-z0-9_]+)"/).flatten
      tables += %w[ar_internal_metadata schema_migrations]
      sql = engine == "postgresql" ? "SELECT tablename AS name FROM pg_tables WHERE schemaname='public'" : "SELECT TABLE_NAME AS name FROM information_schema.tables WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE'"
      current = connection.select_all(sql).map { |row| row.fetch("name") }.sort
      raise Unsafe, "table schema mismatch" unless tables.any? && tables.sort == current
      actual(connection, engine)
    end
    raise Unsafe, "foreign key schema mismatch (expected #{wanted.size}, observed #{observed.size})" unless wanted.any? && wanted == observed
    # One uncached query: a complete FK inventory cannot conceal orphan data
    # left by an interrupted MySQL DDL/data replay. No cleanup/repair follows.
    checks = wanted.map do |from, to, columns, primary, _|
      join = columns.zip(primary).map { |left, right| "f.#{connection.quote_column_name(left)}=p.#{connection.quote_column_name(right)}" }.join(" AND ")
      present = columns.map { |name| "f.#{connection.quote_column_name(name)} IS NOT NULL" }.join(" AND ")
      "SELECT 1 AS orphan WHERE EXISTS (SELECT 1 FROM #{connection.quote_table_name(from)} f LEFT JOIN #{connection.quote_table_name(to)} p ON #{join} WHERE #{present} AND p.#{connection.quote_column_name(primary.first)} IS NULL LIMIT 1)"
    end
    orphan = connection.uncached { connection.select_value(checks.join(" UNION ALL ") + " LIMIT 1") }
    raise Unsafe, "orphan data; retain quarantined fixture" if orphan
    true
  end

  def guard!
    verify!
  rescue Unsafe => error
    warn "UNSAFE SYNTHETIC SCHEMA: #{error.message}; qualification aborted; no automatic schema repair"
    exit 78
  end
end
