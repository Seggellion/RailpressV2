#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
engine="${1:?postgresql|mysql2 required}"
[[ "$engine" == postgresql || "$engine" == mysql2 ]] || exit 1
source scripts/native/ci-source.sh
[[ ! -e .local/state/test-targets.json && ! -e .local/state/qualification ]] || { echo 'Fresh synthetic state required'; exit 1; }
export RAILPRESS_EVIDENCE_MILESTONE=CI
phase=provision
finish() {
  result=$?
  trap - EXIT
  if [[ -f .local/state/test-targets.json ]]; then
    if ! python3 scripts/native/control_databases.py stop --confirm-synthetic; then
      phase=cleanup
      result=1
    fi
  fi
  printf '%s\n' "$phase" > "$RUNNER_TEMP/railpress-ci-phase"
  if (( result != 0 )); then
    printf 'Native CI failed during %s\n' "$phase" >&2
  fi
  exit "$result"
}
trap finish EXIT
python3 scripts/native/provision_databases.py --confirm-synthetic
phase=qualification
bash scripts/native/qualify.sh "$engine"
grep -Eq '^[1-9][0-9]* runs, [1-9][0-9]* assertions, 0 failures, 0 errors, 0 skips$' "docs/evidence/CI/$engine-tests.log"
phase=quality
bash scripts/native/quality.sh
phase=complete
