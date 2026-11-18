#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
engine="${1:?postgresql|mysql2 required}"
[[ "$engine" == postgresql || "$engine" == mysql2 ]] || exit 1
[[ "${GITHUB_REPOSITORY:-}" == Seggellion/RailpressV2 && "${GITHUB_REF:-}" == refs/heads/main ]] || exit 1
[[ ! -e .local/state/test-targets.json && ! -e .local/state/qualification ]] || { echo 'Fresh ephemeral runner required'; exit 1; }
export RAILPRESS_EVIDENCE_MILESTONE=CI
python3 scripts/native/provision_databases.py --confirm-synthetic
trap 'python3 scripts/native/control_databases.py stop --confirm-synthetic' EXIT
bash scripts/native/qualify.sh "$engine"
bash scripts/native/quality.sh
ruby -rjson -rdigest -e 'v=JSON.parse(File.read("lib/railpress/product.json"));File.write(".local/ci-candidate.json",JSON.pretty_generate({version:v.fetch("version"),channel:v.fetch("channel"),engine:ARGV.fetch(0),source_commit:ENV.fetch("GITHUB_SHA"),tests_scans_build:"PASS",signed_release:false,production_qualified:false})+"\n")' "$engine"
