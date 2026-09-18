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
assert_file_contains "$ROOT/lib/compose.sh" 'local -a env_files=(--env-file "$ENV_RELEASE")'
assert_file_contains "$ROOT/lib/compose.sh" 'env_files+=(--env-file "$ENV_DOCKER")'
assert_file_contains "$ROOT/lib/compose.sh" '"${env_files[@]}"'
assert_file_contains "$ROOT/lib/hosts.sh" 'var=COMPOSE_PROFILES'
assert_file_contains "$ROOT/lds" 'compose_control_value()'
assert_file_contains "$ROOT/lds" 'dotenv_value()'
assert_file_contains "$ROOT/lib/compose.sh" 'LDS_AI_RUNTIME cpu'
assert_file_contains "$ROOT/lib/compose.sh" 'LDS_LLM_HOST_PORT 0'
pass "environment file and precedence wiring"

git -C "$ROOT" check-ignore -q docker/.env || fail "docker/.env must remain ignored user state"
git -C "$ROOT" check-ignore -q .env || fail ".env must remain ignored user state"
if git -C "$ROOT" check-ignore -q docker/release.env; then
  fail "docker/release.env must be tracked release state"
fi
pass "release and user env ownership boundaries"

expected=(
  'LDS_TOOLS_IMAGE=infocyph/tools:latest'
  'LDS_RUNNER_IMAGE=infocyph/runner:latest'
  'LDS_NGINX_IMAGE=infocyph/nginx:latest'
  'LDS_APACHE_IMAGE=infocyph/apache:latest'
  'LDS_LLM_IMAGE=infocyph/llm-sm:latest'
  'LDS_LLM_AMD_IMAGE=infocyph/llm-sm:amd-latest'
  'SCRIPTOMATIC_REF=main'
)
for entry in "${expected[@]}"; do
  assert_file_contains "$release_env" "$entry"
done
pass "moving latest image manifest"

assert_file_contains "$ROOT/lib/profiles.sh" 'CATALOG_FILE="$CFG/catalog/services.psv"'
assert_file_contains "$ROOT/lib/profiles.sh" 'load_service_catalog()'
assert_file_contains "$ROOT/lib/profiles.sh" 'load_service_catalog'
pass "profile setup loads the tracked host catalog"

assert_file_contains "$ROOT/lib/ai.sh" 'cmd_ai()'
assert_file_contains "$ROOT/lib/ai.sh" 'cmd_llm()'
assert_file_contains "$ROOT/lib/ai.sh" '_tools_exec_argv()'
assert_file_contains "$ROOT/lds" 'ai) cmd_ai "$@"'
assert_file_contains "$ROOT/lds" 'llm) cmd_llm "$@"'
pass "AI/LLM CLI routing contract"

assert_file_contains "$ROOT/lib/compose.sh" 'dc_cmd build --build-arg "SCRIPTOMATIC_REF=$scriptomatic_ref"'
if grep -R -Fq 'dc_build --no-cache' "$ROOT/lds" "$ROOT/lib"; then
  fail "runtime rebuild path must preserve Docker build cache"
fi
assert_file_contains "$ROOT/lib/services.sh" 'dc_build --pull "$svc"'
pass "runtime rebuilds preserve cache while refreshing selected bases"
