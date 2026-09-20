#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

release_env="$ROOT/docker/release.env"
assert_file "$release_env"
assert_file_contains "$release_env" 'SCRIPTOMATIC_REF=main'

tools_image="infocyph/tools:latest"
runner_image="infocyph/runner:latest"
nginx_image="infocyph/nginx:latest"
apache_image="infocyph/apache:latest"

images=(
  "$tools_image"
  "$runner_image"
  "$nginx_image"
  "$apache_image"
)

for image in "${images[@]}"; do
  [[ -n "$image" ]] || fail "empty infrastructure image in release manifest"
  printf 'Pulling %s\n' "$image"
  docker pull "$image"
  docker image inspect "$image" >/dev/null
done
pass "published infrastructure compatibility images exist"

moving_images=(
  "postgres:alpine"
  "mysql:latest"
  "mariadb:latest"
  "mongo:latest"
  "redis/redis-stack-server:latest"
  "redis/redisinsight:latest"
  "dbeaver/cloudbeaver:latest"
  "mongo-express:latest"
  "axllent/mailpit:latest"
  "elasticsearch:9.5.4"
  "kibana:9.5.4"
  "docker.elastic.co/beats/filebeat:9.5.4"
  "infocyph/llm-ollama:latest"
  "infocyph/llm-ollama:amd-latest"
)

for image in "${moving_images[@]}"; do
  printf 'Checking configured image reference %s\n' "$image"
  docker manifest inspect "$image" >/dev/null
done
pass "all configured current image references resolve"

for image in "$tools_image" "$runner_image"; do
  health="$(docker image inspect "$image" --format '{{json .Config.Healthcheck}}')"
  [[ -n "$health" && "$health" != "null" ]] || fail "$image must publish a healthcheck"
done
pass "Tools and Runner publish healthchecks"

grep -Fq 'image: infocyph/llm-ollama:${LDS_LLM_ARCH}' "$ROOT/docker/compose/companion.yaml" ||
  fail "LLM service must use the single LDS_LLM_ARCH selector"
grep -Fq "amd) printf '%s' amd-latest" "$ROOT/lib/platform.sh" ||
  fail "AMD runtime must map to amd-latest"
pass "LLM image selection follows the single latest/amd-latest tag contract"

tools_profile_chooser="$(
  docker run --rm --entrypoint cat "$tools_image" /usr/local/bin/profile-chooser
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


docker run --rm --entrypoint sh "$tools_image" -lc '
  test -x /usr/local/bin/mkhost
  test -s /etc/share/runtime-versions.json
  jq -e ".php.active | type == \"array\" and length > 0" /etc/share/runtime-versions.json >/dev/null
  jq -e ".node.active | type == \"array\" and length > 0" /etc/share/runtime-versions.json >/dev/null
  grep -Fq "RUNTIME_VERSIONS_DB" /usr/local/bin/mkhost
'
pass "latest Tools preserves interactive PHP/Node runtime version catalog"

php_template="$(
  docker run --rm --entrypoint cat "$tools_image" /etc/docker-templates/php.compose.yaml
)"
node_template="$(
  docker run --rm --entrypoint cat "$tools_image" /etc/docker-templates/node.compose.yaml
)"
assert_contains "$php_template" 'PHP_VERSION: {{PHP_VERSION}}'
assert_contains "$php_template" 'image: localdevstack-php:{{PHP_VERSION}}'
assert_contains "$node_template" 'NODE_VERSION: {{NODE_VERSION}}'
assert_contains "$node_template" 'image: localdevstack-node:{{NODE_VERSION}}'
pass "selected runtime versions remain build/image identity inputs"

docker run --rm --entrypoint sh "$runner_image" -ec '
  test -x /usr/local/bin/logrotate-worker.sh
  test -x /usr/local/bin/runner-healthcheck
  test -f /etc/logrotate.d/daily
  test -f /etc/logrotate.d/supervisord
'
pass "latest Runner preserves logrotate/health contract"

assert_contains "$php_template" './docker/conf/www-php.conf:/usr/local/etc/php-fpm.d/www.conf'
pass "generated PHP runtime uses the maintained FPM pool config"

tools_certify="$(
  docker run --rm --entrypoint cat "$tools_image" /usr/local/bin/certify
)"
assert_contains "$tools_certify" 'EXPORT_DIR="${EXPORT_DIR:-/etc/share/certs}"'
assert_contains "$tools_certify" 'EXPORT_ROOTCA_NAME="${EXPORT_ROOTCA_NAME:-rootCA.pem}"'
assert_contains "$tools_certify" 'atomic_install 0644 "$root_ca" "$EXPORT_DIR/$EXPORT_ROOTCA_NAME"'
pass "latest Tools public TLS export contract"

docker run --rm --entrypoint sh "$tools_image" -ec '
  test -d /etc/share/state
  test -x /usr/local/bin/env-store
  grep -Fq "/etc/share/state/env-store.json" /usr/local/bin/env-store
  grep -Fq "/etc/share/state" /usr/local/bin/monitor-alerts
  grep -Fq "/etc/share/state" /usr/local/bin/monitor-slo
'
pass "latest Tools durable state ABI"
