#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/native/env.sh
engine="${1:?Usage: scripts/native/qualify.sh postgresql|mysql2}"
[[ "$engine" == postgresql || "$engine" == mysql2 ]] || exit 1
milestone="${RAILPRESS_EVIDENCE_MILESTONE:-qualification}"
[[ "$milestone" =~ ^[A-Za-z0-9_-]+$ ]] || exit 1
export RAILPRESS_EVIDENCE_MILESTONE="$milestone"
evidence="docs/evidence/$milestone"
mkdir -p "$evidence"
# Verify forward migration, then separately prove all fresh migrations and schema loading.
# Separate Rails processes keep schema reset independent of migration state.
bin/native_test "$engine" --confirm-synthetic db:migrate > "$evidence/$engine-migrate.log" 2>&1
bin/native_test "$engine" --confirm-synthetic native:empty_schema > "$evidence/$engine-empty-schema.log" 2>&1
bin/native_test "$engine" --confirm-synthetic native:migrate_from_zero db:schema:dump > "$evidence/$engine-fresh-migrate.log" 2>&1
cp "db/schema_$engine.rb" ".local/state/$engine-fresh-schema.rb"
bin/native_test "$engine" --confirm-synthetic native:empty_schema > "$evidence/$engine-schema-empty.log" 2>&1
bin/native_test "$engine" --confirm-synthetic db:schema:load db:migrate db:schema:dump > "$evidence/$engine-schema-load.log" 2>&1
python3 scripts/native/compare_schemas.py "$engine" > "$evidence/$engine-schema-equivalence.log" 2>&1
bin/native_test "$engine" --confirm-synthetic test > "$evidence/$engine-tests.log" 2>&1
bin/native_test "$engine" --confirm-synthetic zeitwerk:check > "$evidence/$engine-zeitwerk.log" 2>&1
tail -n 3 "$evidence/$engine-tests.log"
cat "$evidence/$engine-zeitwerk.log"
