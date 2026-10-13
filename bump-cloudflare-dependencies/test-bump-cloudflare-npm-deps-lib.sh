#!/usr/bin/env bash
# Unit / fixture checks for peer-aware bump lib (WW-239).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="$SCRIPT_DIR/cloudflare-npm-deps.allowlist"
LIB="$SCRIPT_DIR/.bump-cloudflare-npm-deps-lib.mjs"
FIXTURES="$SCRIPT_DIR/fixtures"

node "$LIB" self-test "$ALLOWLIST" "$FIXTURES"

# Dry-run: peer-aware list must not propose vitest 5 for counter-worker historical shape.
assert_vitest_below_major5() {
  local fixture="$1"
  local line
  line="$(node "$LIB" list-upgrades "$FIXTURES/$fixture" "$ALLOWLIST" | grep '^vitest|' || true)"
  if [[ -n "$line" ]]; then
    IFS='|' read -r _pkg _section _cur target _src <<< "$line"
    major="${target%%.*}"
    if [[ "$major" -ge 5 ]]; then
      echo "$fixture: vitest must stay below major 5 (got $target)" >&2
      exit 1
    fi
  fi
}

assert_vitest_below_major5 counter-worker-shape
assert_vitest_below_major5 invest-rss-shape

echo "test-bump-cloudflare-npm-deps-lib: ok"
