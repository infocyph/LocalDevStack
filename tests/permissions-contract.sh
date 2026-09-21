#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

file="$ROOT/lib/platform.sh"
assert_file "$file"
if grep -Eq 'chmod[[:space:]]+-R[[:space:]]+777|chmod[[:space:]]+777' "$file"; then
  fail "broad world-writable permission logic returned"
fi
assert_file_contains "$file" 'owner="${SUDO_USER:-${USER:-}}"'
assert_file_contains "$file" 'find "$DIR/configuration" -type d -exec chmod 2775 {} +'
assert_file_contains "$file" 'find "$DIR/logs" -type d -exec chmod 2775 {} +'
assert_file_contains "$file" 'find "$private_dir" -type d -exec chmod 0700 {} +'
assert_file_contains "$file" 'find "$private_dir" -type f -exec chmod 0600 {} +'
assert_file_contains "$file" '"$DIR/configuration/ssh" "$DIR/configuration/sops/keys"'
pass "host permissions are scoped and secret directories remain private"

assert_file_contains "$file" 'find "$DIR/configuration/ssl" -type f -exec chmod 0644 {} +'
assert_file_contains "$file" "-name '*.p12'"
assert_file_contains "$file" "-name '*-key.pem'"
assert_file_contains "$file" ') -exec chmod 0600 {} +'
pass "TLS public exports remain readable while private/P12 artifacts stay 0600"
