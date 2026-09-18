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

[[ "${release[LDS_LLM_IMAGE]:-}" == "infocyph/llm-sm:latest" ]] ||
  fail "unexpected standard LLM moving image"
[[ "${release[LDS_LLM_AMD_IMAGE]:-}" == "infocyph/llm-sm:amd-latest" ]] ||
  fail "unexpected AMD LLM moving image"
pass "LLM image references follow latest-tag policy"

tools_profile_chooser="$(
  docker run --rm --entrypoint cat "${release[LDS_TOOLS_IMAGE]}" /usr/local/bin/profile-chooser
)"
catalog="$ROOT/docker/catalog/services.psv"

while IFS='|' read -r key profile _display _service_key version_env defaults _prompts _admin _volume _url _category _optional _default_enabled _runtime_modes; do
  [[ -n "$key" && "$key" != \#* ]] || continue
  [[ "$profile" != "ai" ]] || continue

  grep -Fq "[$key]=\"$profile\"" <<<"$tools_profile_chooser" ||
    fail "Tools profile-chooser service mapping drift: $key -> $profile"

  IFS=';' read -r -a catalog_defaults <<<"$defaults"
  for kv in "${catalog_defaults[@]}"; do
    [[ -n "$kv" ]] || continue
    k="${kv%%=*}"
    [[ "$k" == "$version_env" ]] && continue
    grep -Fq "$kv" <<<"$tools_profile_chooser" ||
      fail "Tools profile-chooser non-version default drift for $profile: $kv"
  done

  tools_version="$(
    grep -oE "\[$profile\]=\"[^\"]+\"" <<<"$tools_profile_chooser" |
      grep -oE "(${version_env})=[^ \"]+" | head -n1 || true
  )"
  catalog_version="$(
    printf '%s\n' "${catalog_defaults[@]}" | grep -E "^${version_env}=" | head -n1 || true
  )"
  if [[ -n "$tools_version" && "$tools_version" != "$catalog_version" ]]; then
    printf 'INFO: intentional image-version drift for %s: Tools=%s LocalDevStack=%s\n'       "$profile" "$tools_version" "$catalog_version"
  fi
done <"$catalog"
pass "LocalDevStack catalog matches latest Tools non-version profile contract"


docker run --rm --entrypoint sh "${release[LDS_TOOLS_IMAGE]}" -lc '
  test -x /usr/local/bin/mkhost
  test -s /etc/share/runtime-versions.json
  jq -e ".php.active | type == \"array\" and length > 0" /etc/share/runtime-versions.json >/dev/null
  jq -e ".node.active | type == \"array\" and length > 0" /etc/share/runtime-versions.json >/dev/null
  grep -Fq "RUNTIME_VERSIONS_DB" /usr/local/bin/mkhost
'
pass "latest Tools preserves interactive PHP/Node runtime version catalog"

php_template="$(
  docker run --rm --entrypoint cat "${release[LDS_TOOLS_IMAGE]}" /etc/docker-templates/php.compose.yaml
)"
node_template="$(
  docker run --rm --entrypoint cat "${release[LDS_TOOLS_IMAGE]}" /etc/docker-templates/node.compose.yaml
)"
assert_contains "$php_template" 'PHP_VERSION: {{PHP_VERSION}}'
assert_contains "$php_template" 'image: localdevstack-php:{{PHP_VERSION}}'
assert_contains "$node_template" 'NODE_VERSION: {{NODE_VERSION}}'
assert_contains "$node_template" 'image: localdevstack-node:{{NODE_VERSION}}'
pass "selected runtime versions remain build/image identity inputs"

docker run --rm --entrypoint sh "${release[LDS_RUNNER_IMAGE]}" -ec '
  test -x /usr/local/bin/logrotate-worker.sh
  test -x /usr/local/bin/runner-healthcheck.sh
  test -f /etc/logrotate.d/daily
  test -f /etc/logrotate.d/supervisord
'
pass "latest Runner preserves logrotate/health contract"

assert_contains "$php_template" './docker/conf/www-php.conf:/usr/local/etc/php-fpm.d/www.conf'
pass "generated PHP runtime uses the maintained FPM pool config"
