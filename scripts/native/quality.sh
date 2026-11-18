#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/native/env.sh
milestone="${RAILPRESS_EVIDENCE_MILESTONE:-qualification}"
[[ "$milestone" =~ ^[A-Za-z0-9_-]+$ ]] || exit 1
export RAILPRESS_EVIDENCE_MILESTONE="$milestone"
evidence="docs/evidence/$milestone"
mkdir -p "$evidence" .local/state
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile > $evidence/assets-first.log 2>&1
sha256sum public/assets/.manifest.json > .local/manifest-first.sha256
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile > $evidence/assets-second.log 2>&1
sha256sum -c .local/manifest-first.sha256 > $evidence/assets-reproducibility.log
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails zeitwerk:check > $evidence/production-zeitwerk.log 2>&1
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails runner 'raise "unexpected DB connection" if ActiveRecord::Base.connection_pool.connected?; puts "PRODUCTION BOOT: no DB connection or implicit schema preparation"' > $evidence/production-boot.log 2>&1
if RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/jobs > "$evidence/uninstalled-worker.log" 2>&1; then
  echo "Uninstalled worker unexpectedly started" >&2
  exit 1
fi
grep -q "Worker awaits completed setup" "$evidence/uninstalled-worker.log"
ruby scripts/native/production_smoke.rb > $evidence/production-restart.log 2>&1
bundle exec brakeman --no-pager -o $evidence/brakeman.json > $evidence/brakeman.log 2>&1
bundle exec bundler-audit check --update --database .local/advisories > $evidence/bundler-audit.log 2>&1
bundle exec rubocop --format progress > $evidence/rubocop.log 2>&1
echo "Native assets, boot/restart, security and lint checks passed"
