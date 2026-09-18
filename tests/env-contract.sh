#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

release_env="$ROOT/docker/release.env"

assert_file "$release_env"
assert_file_contains "$ROOT/lds" 'ENV_MAIN="$DIR/.env"'
assert_file_contains "$ROOT/lds" 'ENV_DOCKER="$CFG/.env"'
assert_file_contains "$ROOT/lds" 'ENV_RELEASE="$CFG/release.env"'
assert_file_contains "$ROOT/lds" 'COMPOSE_FILE="$CFG/compose/main.yaml"'
assert_file_contains "$ROOT/lds" 'local -a env_files=(--env-file "$ENV_RELEASE")'
assert_file_contains "$ROOT/lds" 'env_files+=(--env-file "$ENV_DOCKER")'
assert_file_contains "$ROOT/lds" '"${env_files[@]}"'
assert_file_contains "$ROOT/lds" 'var=COMPOSE_PROFILES'
pass "environment file and precedence wiring"

git -C "$ROOT" check-ignore -q docker/.env || fail "docker/.env must remain ignored user state"
git -C "$ROOT" check-ignore -q .env || fail ".env must remain ignored user state"
if git -C "$ROOT" check-ignore -q docker/release.env; then
  fail "docker/release.env must be tracked release state"
fi
pass "release and user env ownership boundaries"

expected=(
  'LDS_TOOLS_IMAGE=infocyph/tools:0.23.2'
  'LDS_RUNNER_IMAGE=infocyph/runner:0.5'
  'LDS_NGINX_IMAGE=infocyph/nginx:0.4.1'
  'LDS_APACHE_IMAGE=infocyph/apache:0.4.2'
  'LDS_LLM_IMAGE=infocyph/llm-sm:0.03'
  'LDS_LLM_AMD_IMAGE=infocyph/llm-sm:amd-0.03'
)
for entry in "${expected[@]}"; do
  assert_file_contains "$release_env" "$entry"
done
pass "published compatibility manifest"

for key in POSTGRESQL MYSQL MARIADB ELASTICSEARCH MONGODB REDIS; do
  grep -Fq "[$key]=" "$ROOT/lds" || fail "missing profile catalog entry: $key"
done
pass "current profile catalog entries"
