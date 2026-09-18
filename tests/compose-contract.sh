#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is required"

release_env="$ROOT/docker/release.env"
user_env="$ROOT/docker/.env"
backup_env=""
had_user_env=0

if [[ -e "$user_env" ]]; then
  had_user_env=1
  backup_env="$(mktemp)"
  cp "$user_env" "$backup_env"
fi

cleanup() {
  if ((had_user_env)); then
    cp "$backup_env" "$user_env"
    rm -f "$backup_env"
  else
    rm -f "$user_env"
  fi
}
trap cleanup EXIT

cat >"$user_env" <<EOF
TZ=UTC
USER=$(id -un)
UID=$(id -u)
GID=$(id -g)
PROJECT_DIR=$ROOT
EOF

compose=(docker compose
  --project-directory "$ROOT"
  -f "$ROOT/docker/compose/main.yaml"
  --env-file "$release_env"
  --env-file "$user_env"
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
assert_contains "$resolved" "image: infocyph/tools:0.23.2"
assert_contains "$resolved" "image: infocyph/runner:0.5"
assert_contains "$resolved" "image: infocyph/nginx:0.4.1"
assert_contains "$resolved" "image: infocyph/apache:0.4.2"
pass "release compatibility defaults resolve"

printf '%s\n' 'LDS_TOOLS_IMAGE=example.invalid/tools:user-override' >>"$user_env"
user_override="$("${compose[@]}" config)"
assert_contains "$user_override" "image: example.invalid/tools:user-override"
pass "docker/.env overrides release defaults"

shell_override="$(
  LDS_TOOLS_IMAGE=example.invalid/tools:shell-override "${compose[@]}" config
)"
assert_contains "$shell_override" "image: example.invalid/tools:shell-override"
pass "shell override wins over user and release env files"

# Apache is currently an unconditional service in the baseline. This is
# characterized here; Batch 5 will make the product's optional-HTTP contract
# explicit rather than silently changing it in the compatibility batch.
assert_contains "$resolved" "apache:"
pass "current Apache compose presence characterized"
