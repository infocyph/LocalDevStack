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
if grep -RqsF '/var/run/docker.sock' "$ROOT/docker/compose/db.yaml" "$ROOT/docker/compose/db-client.yaml" "$ROOT/docker/compose/http.yaml"; then
  fail "Docker socket escaped the trusted Tools/Runner boundary"
fi
pass "Docker socket trust boundary"

assert_file_contains "$db" 'test: ["CMD", "pg_isready", "-h", "127.0.0.1"]'
assert_file_contains "$db" 'test: ["CMD", "mysqladmin", "ping", "-h127.0.0.1", "--silent"]'
assert_file_contains "$db" 'test: ["CMD", "mongosh", "--host", "127.0.0.1", "--quiet", "--eval", "db.adminCommand('\''ping'\'')"]'
if grep -Fq 'PGPASSWORD=' "$db" || grep -Fq ' --password ' "$db"; then
  fail "database readiness probes must not embed credentials"
fi
pass "database health probes are credential-free local readiness checks"

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

certs="$ROOT/lib/certificates.sh"
assert_file_contains "$companion" '../../configuration/ssl:/etc/share/certs'
assert_file_contains "$certs" 'local current="$DIR/configuration/ssl/rootCA.pem"'
assert_file_contains "$certs" 'local legacy="$DIR/configuration/rootCA/rootCA.pem"'
assert_file_contains "$certs" 'src_ca="$(host_root_ca_path || true)"'
pass "certificate export bridge uses the current public host path with legacy fallback"

main="$ROOT/docker/compose/main.yaml"
assert_file_contains "$main" 'name: ToolsState'
assert_file_contains "$companion" 'lds_tools_state:/etc/share/state'
pass "Tools durable state persistence"

assert_file_contains "$ROOT/lib/hosts.sh" 'modify_profiles add "$svr_prof"'
assert_file_contains "$ROOT/lib/hosts.sh" 'modify_profiles remove "$apache_cont"'
if grep -Fq 'profiles: [apache]' "$http"; then
  fail "Apache cannot become profile-only until Admin Panel host lifecycle can manage the profile"
fi
pass "Apache remains always available so CLI and Admin Panel host creation retain parity"

cert_helper_uses="$(grep -c 'src_ca="$(host_root_ca_path || true)"' "$certs")"
[[ "$cert_helper_uses" -ge 3 ]] ||
  fail "Windows install/uninstall and Unix install must all use host_root_ca_path"
if grep -Fq 'local src_ca="$DIR/configuration/rootCA/rootCA.pem"' "$certs"; then
  fail "Unix CA install regressed to the legacy-only path"
fi
pass "all CA install paths use current export with legacy fallback"

assert_file_contains "$companion" 'COMPOSE_PROFILES=${COMPOSE_PROFILES:-}'
pass "Tools profile visibility follows LocalDevStack profile selection"

if awk '/^  llm-ollama:/ { in_llm=1; next } in_llm && /^  [a-zA-Z0-9_-]+:/ { in_llm=0 } in_llm { print }' "$companion" | grep -Eq '/var/run/docker.sock|PROJECT_DIR|/app'; then
  fail "llm-ollama must not receive Docker socket or project mounts"
fi
pass "companion-owned mutually exclusive LLM providers keep the AI trust boundary"
