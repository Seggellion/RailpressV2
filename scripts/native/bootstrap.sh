#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/native/env.sh
[[ "$(ruby -e 'print RUBY_VERSION')" == 3.4.12 ]] || { echo "Install the documented Ruby 3.4.12 native runtime" >&2; exit 1; }
: "${RAILPRESS_PG_BIN:?Set the directory containing qualified PostgreSQL16.16 tools}"
: "${RAILPRESS_MYSQL_HOME:?Set the qualified MySQL8.4.13 native installation prefix}"
[[ "$("$RAILPRESS_PG_BIN/postgres" --version)" == *16.16* ]]
[[ "$("$RAILPRESS_MYSQL_HOME/bin/mysqld" --version)" == *8.4.13* ]]
bundle _4.0.24_ install
bundle check
echo "Dependencies ready. Provision only a fresh dedicated fixture with scripts/native/provision_databases.py --confirm-synthetic."
