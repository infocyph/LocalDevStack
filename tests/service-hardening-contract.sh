#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

companion="$ROOT/docker/compose/companion.yaml"
http="$ROOT/docker/compose/http.yaml"
db="$ROOT/docker/compose/db.yaml"
clients="$ROOT/docker/compose/db-client.yaml"
filebeat="$ROOT/docker/conf/filebeat.yml"
pg_ref="$ROOT/docker/conf/postgresql.conf"

socket_count="$(grep -RhsF '/var/run/docker.sock:/var/run/docker.sock' "$ROOT/docker/compose" | wc -l | tr -d ' ')"
[[ "$socket_count" -eq 2 ]] || fail "Docker socket must be mounted only by Tools and Runner; found $socket_count compose mounts"
assert_file_contains "$companion" '/var/run/docker.sock:/var/run/docker.sock'
if grep -RqsF '/var/run/docker.sock' "$ROOT/docker/compose/ai.yaml" "$ROOT/docker/compose/db.yaml" "$ROOT/docker/compose/db-client.yaml" "$ROOT/docker/compose/http.yaml"; then
  fail "Docker socket escaped the trusted Tools/Runner boundary"
fi
pass "Docker socket trust boundary"

assert_file_contains "$db" 'PGPASSWORD="$${POSTGRES_PASSWORD}" pg_isready -U "$${POSTGRES_USER}" -h 127.0.0.1 -d "$${POSTGRES_DB}"'
assert_file_contains "$db" 'mysqladmin ping -h127.0.0.1 -u root -p"$${MYSQL_ROOT_PASSWORD}"'
assert_file_contains "$db" 'mysqladmin ping -h127.0.0.1 -u root -p"$${MARIADB_ROOT_PASSWORD}"'
assert_file_contains "$db" '--username "$${MONGO_INITDB_ROOT_USERNAME}" --password "$${MONGO_INITDB_ROOT_PASSWORD}"'
if grep -Fq '${POSTGRES_DB:-postgres}' "$db"; then
  fail "PostgreSQL healthcheck must probe the container POSTGRES_DB value"
fi
pass "database health probes use container runtime state"

for file in "$companion" "$http" "$clients"; do
  assert_file_contains "$file" 'condition: service_healthy'
done
pass "service consumers wait for declared dependency health"

assert_file_contains "$filebeat" 'hosts: ["http://elasticsearch:9200"]'
assert_file_contains "$filebeat" 'host: "http://kibana:5601"'
pass "Filebeat uses service DNS"

assert_file_contains "$pg_ref" '# INACTIVE REFERENCE CONFIGURATION'
if grep -Fq 'postgresql.conf:/etc/postgresql/postgresql.conf' "$db"; then
  fail "inactive postgresql.conf must not be pseudo-wired in Compose"
fi
[[ ! -e "$ROOT/docker/conf/www.conf" ]] || fail "unused legacy docker/conf/www.conf must remain removed"
assert_file "$ROOT/docker/conf/www-php.conf"
pass "Docker config ownership is explicit"
