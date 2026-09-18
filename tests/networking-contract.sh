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
pghba="$ROOT/docker/conf/pg_hba.conf"

for network in frontend backend datastore; do
  grep -Eq "^  ${network}:" "$main" || fail "missing logical network: $network"
done
pass "logical network names"

for runtime_file in "$ROOT"/docker/compose/*.yaml "$pghba"; do
  if grep -Eq 'ipv4_address:|172\.28\.0\.|172\.29\.0\.|172\.30\.0\.' "$runtime_file"; then
    fail "static LocalDevStack network dependency remains in $runtime_file"
  fi
done
pass "fixed LocalDevStack addresses removed"

schema_count="$(grep -c 'com.infocyph.network-schema: "dynamic-v1"' "$main")"
[[ "$schema_count" -eq 3 ]] || fail "expected dynamic-v1 schema label on all three networks"
if grep -q '^[[:space:]]*ipam:' "$main"; then
  fail "main compose must not define fixed IPAM"
fi
pass "dynamic network schema"

assert_file_contains "$clients" '@mongodb:'
assert_file_contains "$clients" 'ELASTICSEARCH_HOSTS=http://elasticsearch:9200'
assert_file_contains "$companion" 'hostname: runner'
assert_file_contains "$http" 'hostname: nginx'
assert_file_contains "$db" 'hostname: postgres'
assert_file_contains "$pghba" 'samenet'
pass "service-name/Docker-DNS contracts are present"

if grep -Fq 'host.docker.internal:host-gateway' "$http"; then
  fail "unused host-gateway mapping should not remain in the HTTP layer"
fi
assert_file_contains "$http" 'restart: unless-stopped'
pass "HTTP network/restart cleanup"

assert_file_contains "$ROOT/lds" 'migrate_legacy_networks()'
assert_file_contains "$ROOT/lds" 'docker_compose down --remove-orphans'
assert_file_contains "$ROOT/lds" 'com.infocyph.network-schema'
assert_file_contains "$ROOT/lds" 'cmd_vpn_fix()'
assert_file_contains "$ROOT/lds" 'vpn-fix) cmd_vpn_fix "$@"'
assert_file_contains "$ROOT/lds" 'migrate_legacy_networks'
pass "safe legacy-network migration and vpn-fix deprecation"
