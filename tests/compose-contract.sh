#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is required"

env_file="$ROOT/docker/.env"
created_env=0
if [[ ! -e "$env_file" ]]; then
  created_env=1
  cat >"$env_file" <<EOF
TZ=UTC
USER=$(id -un)
UID=$(id -u)
GID=$(id -g)
PROJECT_DIR=$ROOT
EOF
fi
cleanup() {
  ((created_env == 0)) || rm -f "$env_file"
}
trap cleanup EXIT

compose=(docker compose
  --project-directory "$ROOT"
  -f "$ROOT/docker/compose/main.yaml"
  --env-file "$env_file"
)

render() {
  local name="$1"
  shift
  printf 'Validating Compose matrix: %s\n' "$name"
  "${compose[@]}" "$@" config --quiet
}

render core
render mysql --profile mysql
render mariadb --profile mariadb
render postgresql --profile postgresql
render mongodb --profile mongodb
render redis --profile redis
render elasticsearch --profile elasticsearch
render elasticsearch-filebeat --profile elasticsearch --profile filebeat

resolved="$("${compose[@]}" --profile mysql config)"
assert_contains "$resolved" "server-tools:"
assert_contains "$resolved" "nginx:"
assert_contains "$resolved" "mysql:"
assert_contains "$resolved" "cloudbeaver:"
pass "representative services resolve"

# Apache is currently an unconditional service in the baseline. This is
# characterized here; Batch 5 will make the product's optional-HTTP contract
# explicit rather than silently changing it in the CI foundation batch.
assert_contains "$resolved" "apache:"
pass "current Apache compose presence characterized"
