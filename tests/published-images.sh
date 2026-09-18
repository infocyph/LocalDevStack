#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

release_env="$ROOT/docker/release.env"
assert_file "$release_env"

declare -A release=()
while IFS='=' read -r key value; do
  [[ -n "$key" && "$key" != \#* ]] || continue
  release["$key"]="$value"
done <"$release_env"

images=(
  "${release[LDS_TOOLS_IMAGE]:-}"
  "${release[LDS_RUNNER_IMAGE]:-}"
  "${release[LDS_NGINX_IMAGE]:-}"
  "${release[LDS_APACHE_IMAGE]:-}"
)

for image in "${images[@]}"; do
  [[ -n "$image" ]] || fail "empty infrastructure image in release manifest"
  printf 'Pulling %s\n' "$image"
  docker pull "$image"
  docker image inspect "$image" >/dev/null
done
pass "published infrastructure compatibility images exist"

for image in "${release[LDS_TOOLS_IMAGE]}" "${release[LDS_RUNNER_IMAGE]}"; do
  health="$(docker image inspect "$image" --format '{{json .Config.Healthcheck}}')"
  [[ -n "$health" && "$health" != "null" ]] || fail "$image must publish a healthcheck"
done
pass "Tools and Runner publish healthchecks"

[[ "${release[LDS_LLM_IMAGE]:-}" == "infocyph/llm-sm:0.03" ]] ||
  fail "unexpected LLM compatibility image"
[[ "${release[LDS_LLM_AMD_IMAGE]:-}" == "infocyph/llm-sm:amd-0.03" ]] ||
  fail "unexpected AMD LLM compatibility image"
pass "LLM compatibility references are release-pinned"

tools_profile_chooser="$(
  docker run --rm --entrypoint cat "${release[LDS_TOOLS_IMAGE]}" /usr/local/bin/profile-chooser
)"
catalog="$ROOT/docker/catalog/services.psv"

while IFS='|' read -r key profile _display _service_key _version_env defaults _prompts _admin _volume _url _category _optional _default_enabled _runtime_modes; do
  [[ -n "$key" && "$key" != \#* ]] || continue
  [[ "$profile" != "ai" ]] || continue

  expected_defaults="${defaults//;/ }"
  grep -Fq "[$key]=\"$profile\"" <<<"$tools_profile_chooser" ||
    fail "Tools profile-chooser service mapping drift: $key -> $profile"
  grep -Fq "[$profile]=\"$expected_defaults\"" <<<"$tools_profile_chooser" ||
    fail "Tools profile-chooser defaults drift for profile: $profile"
done <"$catalog"
pass "LocalDevStack catalog matches overlapping Tools 0.23.2 profile defaults"
