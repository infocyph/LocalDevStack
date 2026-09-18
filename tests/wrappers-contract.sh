#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

wrappers=(
  tool-runner php composer pg my maria mongo redis-cli es
)

for name in "${wrappers[@]}"; do
  file="$ROOT/bin/$name"
  assert_file "$file"
  bash -n "$file"
  if grep -Eq '172\.(28|29|30)\.' "$file"; then
    fail "$name contains a removed fixed-network address"
  fi
done
pass "wrapper syntax and Docker-DNS independence"

runner="$ROOT/bin/tool-runner"
assert_file_contains "$runner" '[[ -t 0 ]] && flags+=(-i)'
assert_file_contains "$runner" '[[ -t 1 ]] && flags+=(-t)'
assert_file_contains "$runner" 'MSYS_NO_PATHCONV=1'
assert_file_contains "$runner" 'MSYS2_ARG_CONV_EXCL='
assert_file_contains "$runner" '--network "container:$SERVER_TOOLS_CONTAINER"'
assert_file_contains "$runner" '--volumes-from "$SERVER_TOOLS_CONTAINER"'
assert_file_contains "$runner" 'exec "$(bin_path docker)" run'
pass "tool-runner preserves TTY, path, namespace and exit-code contracts"

php="$ROOT/bin/php"
assert_file_contains "$php" '-V|--v|--php)'
assert_file_contains "$php" 'pick_highest_php_container()'
assert_file_contains "$php" 'SERVER_TOOLS_VERSION="$(server_tools_php_version || true)"'
assert_file_contains "$php" '--network "container:${NETWORK_SOURCE_CONTAINER}"'
assert_file_contains "$php" 'MSYS_NO_PATHCONV=1'
pass "PHP wrapper preserves explicit/highest runtime selection"

composer="$ROOT/bin/composer"
assert_file_contains "$composer" 'select_runtime()'
assert_file_contains "$composer" 'running_php_versions()'
assert_file_contains "$composer" 'server_tools_php_version()'
assert_file_contains "$composer" '--network "container:$TARGET_CONTAINER"'
assert_file_contains "$composer" 'MSYS_NO_PATHCONV=1'
pass "Composer wrapper preserves PHP runtime resolution"

assert_file_contains "$ROOT/bin/pg" 'SERVICE="${POSTGRESQL_CONTAINER:-${POSTGRES_CONTAINER:-POSTGRESQL}}"'
assert_file_contains "$ROOT/bin/my" 'SERVICE="${MYSQL_CONTAINER:-MYSQL}"'
assert_file_contains "$ROOT/bin/maria" 'SERVICE="${MARIADB_CONTAINER:-${MYSQL_CONTAINER:-MARIADB}}"'
assert_file_contains "$ROOT/bin/mongo" 'SERVICE_DEFAULT="MONGODB"'
assert_file_contains "$ROOT/bin/redis-cli" 'SERVICE="${REDIS_CONTAINER:-REDIS}"'
assert_file_contains "$ROOT/bin/es" 'SERVICE="${ELASTICSEARCH_SERVICE:-ELASTICSEARCH}"'
pass "database wrappers resolve logical service/container identities"

for name in pg my maria mongo redis-cli es; do
  file="$ROOT/bin/$name"
  if grep -Eq '172\.(28|29|30)\.|--host[= ]172\.' "$file"; then
    fail "$name still assumes a LocalDevStack bridge address"
  fi
done
pass "database wrappers have no static subnet assumptions"

# Loopback inside the selected database/container namespace is intentional.
assert_file_contains "$ROOT/bin/pg" '-h127.0.0.1'
assert_file_contains "$ROOT/bin/my" 'host=127.0.0.1'
assert_file_contains "$ROOT/bin/maria" 'host=127.0.0.1'
assert_file_contains "$ROOT/bin/mongo" '@127.0.0.1:27017'
assert_file_contains "$ROOT/bin/es" 'ES_HOST="${ELASTICSEARCH_HOST:-127.0.0.1}"'
pass "database loopback use remains container-local, not bridge addressing"
