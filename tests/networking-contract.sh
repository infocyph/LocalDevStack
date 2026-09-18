#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

main="$ROOT/docker/compose/main.yaml"
db="$ROOT/docker/compose/db.yaml"
clients="$ROOT/docker/compose/db-client.yaml"
companion="$ROOT/docker/compose/companion.yaml"
http="$ROOT/docker/compose/http.yaml"

for network in frontend backend datastore; do
  grep -Eq "^  ${network}:" "$main" || fail "missing logical network: $network"
done
pass "logical network names"

assert_file_contains "$clients" '@mongodb:'
assert_file_contains "$clients" 'ELASTICSEARCH_HOSTS=http://elasticsearch:9200'
assert_file_contains "$companion" 'hostname: runner'
assert_file_contains "$http" 'hostname: nginx'
assert_file_contains "$db" 'hostname: postgres'
pass "service-name/Docker-DNS contracts are present"

static_count="$(
  grep -Rhs 'ipv4_address:'     "$ROOT/docker/compose"     | wc -l | tr -d ' '
)"
printf 'INFO: baseline contains %s explicit ipv4_address declarations; Batch 3 removes them.\n' "$static_count"

if [[ "$static_count" -gt 0 ]]; then
  grep -Fq '172.28.0.0/24' "$main" || fail "baseline frontend subnet changed unexpectedly"
  grep -Fq '172.29.0.0/24' "$main" || fail "baseline backend subnet changed unexpectedly"
  grep -Fq '172.30.0.0/24' "$main" || fail "baseline datastore subnet changed unexpectedly"
fi

pass "static-network baseline characterized"
