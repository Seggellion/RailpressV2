#!/usr/bin/env bash
# Source from repository root to select its private native runtime.
RAILPRESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -x "$RAILPRESS_ROOT/.local/runtime/m16-ruby-3.4.12/bin/ruby" ]]; then
  export PATH="$RAILPRESS_ROOT/.local/runtime/m16-ruby-3.4.12/bin:$PATH"
elif [[ -x "$RAILPRESS_ROOT/.local/runtime/ruby-3.4.12/bin/ruby" ]]; then
  export PATH="$RAILPRESS_ROOT/.local/runtime/ruby-3.4.12/bin:$PATH"
fi
export RUBOCOP_CACHE_ROOT="$RAILPRESS_ROOT/.local/cache/rubocop"
export XDG_DATA_HOME="$RAILPRESS_ROOT/.local/share"
export BUNDLE_USER_HOME="$RAILPRESS_ROOT/.local/bundle-user"
