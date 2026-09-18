#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

assert_file_contains "$ROOT/lds" 'ENV_MAIN="$DIR/.env"'
assert_file_contains "$ROOT/lds" 'ENV_DOCKER="$CFG/.env"'
assert_file_contains "$ROOT/lds" 'COMPOSE_FILE="$CFG/compose/main.yaml"'
assert_file_contains "$ROOT/lds" '--env-file "$ENV_DOCKER"'
assert_file_contains "$ROOT/lds" 'var=COMPOSE_PROFILES'
pass "environment file and profile locations"

git -C "$ROOT" check-ignore -q docker/.env || fail "docker/.env must remain ignored user state"
git -C "$ROOT" check-ignore -q .env || fail ".env must remain ignored user state"
pass "user env files are not tracked"

for key in POSTGRESQL MYSQL MARIADB ELASTICSEARCH MONGODB REDIS; do
  grep -Fq "[$key]=" "$ROOT/lds" || fail "missing profile catalog entry: $key"
done
pass "current profile catalog entries"
