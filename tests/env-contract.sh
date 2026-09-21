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
assert_file_contains "$ROOT/lib/compose.sh" 'compose_control_value LDS_AI_RUNTIME ""'
if grep -RqsF 'LDS_LLM_ARCH' "$ROOT/lib" "$ROOT/docker/compose" "$ROOT/docker/catalog"; then
  fail "obsolete LDS_LLM_ARCH remains in active environment wiring"
fi
pass "environment file and precedence wiring"

git -C "$ROOT" check-ignore -q docker/.env || fail "docker/.env must remain ignored user state"
git -C "$ROOT" check-ignore -q .env || fail ".env must remain ignored user state"
if git -C "$ROOT" check-ignore -q docker/release.env; then
  fail "docker/release.env must be tracked release state"
fi
pass "release and user env ownership boundaries"

expected=(
  'SCRIPTOMATIC_REF=main'
)
for entry in "${expected[@]}"; do
  assert_file_contains "$release_env" "$entry"
done
pass "release env contains only genuinely variable release defaults"

assert_file_contains "$ROOT/lib/profiles.sh" 'CATALOG_FILE="$CFG/catalog/services.psv"'
assert_file_contains "$ROOT/lib/profiles.sh" 'load_service_catalog()'
assert_file_contains "$ROOT/lib/profiles.sh" 'load_service_catalog'
assert_file_contains "$ROOT/lib/profiles.sh" 'configured; Enter keeps current'
assert_file_contains "$ROOT/lib/services.sh" 'docker_compose config --profiles'
assert_file_contains "$ROOT/lib/services.sh" 'Unknown profile: $p'
pass "profile setup loads the catalog, preserves user state, and validates effective profiles"

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


# Profile setup replaces catalog-managed service profiles while preserving
# generated runtime/domain profiles.
profile_tmp="$(mktemp -d)"
(
  set -euo pipefail
  CFG="$ROOT/docker"
  ENV_DOCKER="$profile_tmp/docker.env"
  CYAN="" NC="" BLUE="" YELLOW="" GREEN=""
  die() { printf 'die: %s\n' "$*" >&2; exit 1; }
  dotenv_value() {
    local file="$1" key="$2" line
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)"
    [[ -n "$line" ]] || return 1
    printf '%s' "${line#*=}"
  }
  # shellcheck source=lib/env.sh
  source "$ROOT/lib/env.sh"
  # shellcheck source=lib/profiles.sh
  source "$ROOT/lib/profiles.sh"
  printf '%s\n' 'COMPOSE_PROFILES=mysql,redis,ai,apache,php84' >"$ENV_DOCKER"
  PENDING_PROFILES=(postgresql)
  flush_profiles
  actual="$(grep '^COMPOSE_PROFILES=' "$ENV_DOCKER" | tail -n1)"
  [[ "$actual" == 'COMPOSE_PROFILES=postgresql,apache,php84' ]] ||
    fail "profile reselection drifted: $actual"

  printf '%s\n' 'COMPOSE_PROFILES=mysql,redis,ai,apache,php84' >"$ENV_DOCKER"
  PENDING_PROFILES=()
  flush_profiles
  actual="$(grep '^COMPOSE_PROFILES=' "$ENV_DOCKER" | tail -n1)"
  [[ "$actual" == 'COMPOSE_PROFILES=apache,php84' ]] ||
    fail "NONE selection did not clear only catalog-managed profiles: $actual"

  [[ "$(setup_menu_parse n)" == "NONE" ]] || fail "profile menu NONE token drifted"
  [[ "$(setup_menu_parse q)" == "CANCEL" ]] || fail "profile menu CANCEL token drifted"

  printf '%s\n' 'REDIS_VERSION=7.4-alpine' >>"$ENV_DOCKER"
  read_default() { printf '%s' "$2"; }
  PENDING_ENVS=()
  PENDING_PROFILES=()
  setup_service REDIS >/dev/null
  [[ "${PENDING_ENVS[0]:-}" == 'REDIS_VERSION=7.4-alpine' ]] ||
    fail "profile setup did not preserve configured value"
)
rm -rf "$profile_tmp"
pass "profile setup replaces/clears managed selections while preserving generated profiles and configured values"

assert_file_contains "$ROOT/lib/compose.sh" 'compose_control_value COMPOSE_PROJECT_NAME LocalDevStack'
pass "CLI project identity follows the Compose project contract"


(
  set -euo pipefail
  has_cmd() { return 1; }
  source "$ROOT/lib/platform.sh"
  [[ "$(ai_provider_for_runtime cpu)" == "ollama" ]] || fail "CPU provider drift"
  [[ "$(ai_provider_for_runtime nvidia)" == "ollama" ]] || fail "NVIDIA provider drift"
  [[ "$(ai_provider_for_runtime amd)" == "ollama" ]] || fail "AMD provider drift"
  [[ "$(ai_provider_for_runtime npu)" == "fastflow" ]] || fail "NPU provider drift"
  [[ "$(ai_service_for_runtime npu)" == "llm-fastflow" ]] || fail "NPU service drift"
  [[ "$(ai_service_for_runtime cpu)" == "llm-ollama" ]] || fail "Ollama service drift"
  [[ "$(ai_model_default_for_runtime npu)" == "qwen3.5:9b" ]] || fail "FastFlow model default drift"
  [[ "$(ai_model_default_for_runtime cpu)" == "qwen3:14b" ]] || fail "Ollama model default drift"
  host_cpu_is_amd() { return 0; }
  [[ "$(ai_igpu_default_for_runtime amd)" == "1" ]] || fail "AMD CPU + AMD runtime must enable iGPU"
  [[ "$(ai_igpu_default_for_runtime cpu)" == "0" ]] || fail "CPU runtime must not enable iGPU"
  [[ "$(ai_igpu_default_for_runtime nvidia)" == "0" ]] || fail "NVIDIA runtime must not enable AMD iGPU"
  host_cpu_is_amd() { return 1; }
  [[ "$(ai_igpu_default_for_runtime amd)" == "0" ]] || fail "non-AMD CPU must not auto-enable iGPU"
)
pass "LLM runtime maps mutually exclusive providers, models and AMD iGPU defaults deterministically"

ai_env_tmp="$(mktemp -d)"
(
  set -euo pipefail
  DIR="$ROOT"
  CFG="$ROOT/docker"
  ENV_RELEASE="$ROOT/docker/release.env"
  ENV_DOCKER="$ai_env_tmp/docker.env"
  YELLOW="" NC=""
  die() { printf "die: %s
" "$*" >&2; exit 1; }
  dotenv_value() {
    local file="$1" key="$2" line
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)"
    [[ -n "$line" ]] || return 1
    printf "%s" "${line#*=}"
  }
  compose_control_value() {
    local key="$1" fallback="${2:-}" value=""
    if [[ -n "${!key+x}" ]]; then printf "%s" "${!key}"; return 0; fi
    value="$(dotenv_value "$ENV_DOCKER" "$key" 2>/dev/null || true)"
    [[ -n "$value" ]] && { printf "%s" "$value"; return 0; }
    value="$(dotenv_value "$ENV_RELEASE" "$key" 2>/dev/null || true)"
    [[ -n "$value" ]] && { printf "%s" "$value"; return 0; }
    printf "%s" "$fallback"
  }
  source "$ROOT/lib/env.sh"
  source "$ROOT/lib/platform.sh"
  source "$ROOT/lib/certificates.sh"
  detect_ai_runtime() { printf "%s" amd; }
  host_cpu_is_amd() { return 0; }
  add_required_env
  grep -Fxq "LDS_AI_RUNTIME=amd" "$ENV_DOCKER" || fail "detected AI runtime was not persisted"
  grep -Fxq "LDS_AI_IGPU_ENABLE=1" "$ENV_DOCKER" || fail "AMD CPU iGPU preference was not persisted"

  update_env "$ENV_DOCKER" LDS_AI_RUNTIME nvidia
  update_env "$ENV_DOCKER" LDS_AI_IGPU_ENABLE 0
  detect_ai_runtime() { printf "%s" amd; }
  add_required_env
  grep -Fxq "LDS_AI_RUNTIME=nvidia" "$ENV_DOCKER" || fail "explicit runtime must win over detection"
  grep -Fxq "LDS_AI_IGPU_ENABLE=0" "$ENV_DOCKER" || fail "explicit iGPU preference must be preserved"
)
rm -rf "$ai_env_tmp"
pass "setup bootstrap persists detection without overriding an explicit runtime"

for stale in LDS_TOOLS_IMAGE LDS_RUNNER_IMAGE LDS_NGINX_IMAGE LDS_APACHE_IMAGE; do
  if grep -RqsF "$stale" "$ROOT/docker/compose" "$ROOT/docker/release.env" "$ROOT/lib"; then
    fail "fixed infrastructure image still has unnecessary variable: $stale"
  fi
done
pass "fixed Tools/Runner/Nginx/Apache images have no env indirection"

for stale in ai-nvidia.yaml ai-amd.yaml ai-host-port.yaml; do
  [[ ! -e "$ROOT/docker/compose/$stale" ]] || fail "stale AI Compose overlay remains: $stale"
done
assert_file_contains "$ROOT/lib/compose.sh" 'mktemp "$CFG/.runtime/ai.XXXXXX"'
pass "AI runtime overrides are ephemeral rather than tracked Compose files"
