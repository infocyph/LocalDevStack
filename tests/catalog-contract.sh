#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

catalog="$ROOT/docker/catalog/services.psv"
assert_file "$catalog"

declare -A seen_keys=()
declare -A seen_profiles=()
declare -a order=()

while IFS='|' read -r key profile display service_key version_env defaults prompts admin_client volume url category optional default_enabled runtime_modes; do
  [[ -n "$key" && "$key" != \#* ]] || continue

  [[ -n "$profile" ]] || fail "catalog row missing profile: $key"
  [[ -n "$display" ]] || fail "catalog row missing display name: $key"
  [[ -n "$service_key" ]] || fail "catalog row missing service key: $key"
  [[ -n "$version_env" ]] || fail "catalog row missing version env: $key"
  [[ -n "$category" ]] || fail "catalog row missing category: $key"
  [[ -z "$admin_client" || "$admin_client" =~ ^[a-z0-9-]+$ ]] ||
    fail "catalog admin client invalid: $key"
  [[ "$optional" =~ ^[01]$ ]] || fail "catalog optional flag invalid: $key"
  [[ "$default_enabled" =~ ^[01]$ ]] || fail "catalog default_enabled flag invalid: $key"
  [[ -z "${seen_keys[$key]:-}" ]] || fail "duplicate catalog key: $key"
  [[ -z "${seen_profiles[$profile]:-}" ]] || fail "duplicate catalog profile: $profile"

  seen_keys["$key"]=1
  seen_profiles["$profile"]=1
  order+=("$key")

  [[ -n "$defaults" ]] || fail "catalog setup defaults missing: $key"
  [[ -n "$prompts" ]] || fail "catalog setup prompts missing: $key"

  IFS=';' read -r -a default_items <<<"$defaults"
  IFS=';' read -r -a prompt_items <<<"$prompts"
  [[ "${#default_items[@]}" -eq "${#prompt_items[@]}" ]] ||
    fail "catalog prompts/defaults count mismatch: $key"

  if [[ -n "$url" && "$url" != https://*.localhost ]]; then
    fail "catalog convenience URL must use local HTTPS: $key"
  fi

  case "$key" in
  POSTGRESQL|MYSQL|MARIADB|MONGODB|REDIS)
    [[ -n "$volume" ]] || fail "persistent service missing volume metadata: $key"
    ;;
  AI)
    [[ "$profile" == "ai" ]] || fail "AI profile must be ai"
    [[ "$service_key" == "llm-ollama" ]] || fail "AI service key must be llm-ollama"
    [[ "$runtime_modes" == "cpu,nvidia,amd" ]] || fail "AI runtime metadata drift"
    [[ "$defaults" == *"LDS_AI_MODEL=qwen3:14b"* ]] || fail "AI model default drift"
    [[ "$version_env" == "LDS_LLM_ARCH" ]] || fail "AI image selector must be LDS_LLM_ARCH"
    [[ "$defaults" != *"LDS_AI_RUNTIME="* ]] || fail "AI profile wizard must not prompt for runtime"
    ;;
  ELASTICSEARCH)
    [[ "$defaults" == *"ELASTICSEARCH_VERSION=latest"* ]] || fail "Elastic latest default drift"
    ;;
  esac
done <"$catalog"

expected=(POSTGRESQL MYSQL MARIADB ELASTICSEARCH MONGODB REDIS AI)
[[ "${order[*]}" == "${expected[*]}" ]] ||
  fail "catalog order/coverage drift: ${order[*]}"

pass "canonical host service catalog schema and coverage"
