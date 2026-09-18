#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

index="$ROOT/docs/index.rst"
readme="$ROOT/README.md"
quick="$ROOT/docs/quickstart.rst"
arch="$ROOT/docs/concepts/architecture.rst"
profiles="$ROOT/docs/concepts/profiles-and-env.rst"
storage="$ROOT/docs/concepts/storage-layout.rst"
domain="$ROOT/docs/guides/domain-setup.rst"
tls="$ROOT/docs/guides/tls-and-certificates.rst"
ai="$ROOT/docs/guides/local-ai.rst"
databases="$ROOT/docs/guides/databases-and-clients.rst"
ops="$ROOT/docs/guides/operations-and-support.rst"
runner="$ROOT/docs/guides/ad-hoc-runner.rst"
notify="$ROOT/docs/guides/notifications.rst"
secrets="$ROOT/docs/guides/secrets-sops-age.rst"
cli="$ROOT/docs/reference/cli.rst"

for file in "$index" "$readme" "$quick" "$arch" "$profiles" "$storage" "$domain" "$tls" "$ai" "$databases" "$ops" "$runner" "$notify" "$secrets" "$cli"; do
  assert_file "$file"
done

assert_file_contains "$index" 'guides/local-ai'
assert_file_contains "$index" 'guides/databases-and-clients'
assert_file_contains "$index" 'guides/operations-and-support'
assert_file_contains "$index" 'guides/ad-hoc-runner'
assert_file_contains "$index" 'reference/cli'
assert_file_contains "$readme" 'Dynamic Docker networking through service DNS'
assert_file_contains "$arch" 'Docker assigns their address ranges dynamically'
assert_file_contains "$domain" 'generated runtime Compose fragments are written under configuration/compose/'
assert_file_contains "$domain" 'Domain listing reads the NginxHosts named volume'
assert_file_contains "$storage" 'support traces, and support bundles'
assert_file_contains "$readme" 'lds clean --global --yes'
assert_file_contains "$arch" 'Apache'
assert_file_contains "$arch" 'COMPOSE_PROJECT_NAME'
assert_file_contains "$databases" 'CloudBeaver'
assert_file_contains "$ops" 'lds support bundle'
assert_file_contains "$ops" 'lds clean --global --yes'
assert_file_contains "$runner" 'lds run --sock'
assert_file_contains "$notify" 'Windows/Git Bash'
assert_file_contains "$cli" 'lds llm host-port'
pass "docs describe current architecture, operations, and complete user surfaces"

assert_file_contains "$profiles" 'docker/release.env'
assert_file_contains "$profiles" 'docker/.env'
assert_file_contains "$profiles" 'SCRIPTOMATIC_REF=main'
assert_file_contains "$profiles" 'localdevstack-php:<selected-version>'
assert_file_contains "$profiles" 'localdevstack-node:<selected-version>'
pass "docs preserve env precedence and runtime version selection"

assert_file_contains "$storage" 'configuration/ssl/rootCA.pem'
assert_file_contains "$tls" 'configuration/ssl/rootCA.pem'
assert_file_contains "$tls" 'configuration/rootCA/rootCA.pem'
assert_file_contains "$storage" 'SSLKeys / SSLRootCA'
assert_file_contains "$storage" 'ToolsState'
pass "docs distinguish persistent runtime/control state and public TLS exports"

assert_file_contains "$ai" 'http://llm-sm:11434'
assert_file_contains "$ai" 'https://llm.localhost'
assert_file_contains "$ai" '127.0.0.1:11434'
assert_file_contains "$ai" 'no Docker socket'
assert_file_contains "$ai" 'no project/repository bind mount'
assert_file_contains "$ai" 'automatically execute model-generated shell commands'
assert_file_contains "$ai" 'linux/amd64 only'
assert_file_contains "$ai" 'does not mount the project/repository into llm-sm by default'
assert_file_contains "$ai" 'infocyph/llm-sm:${LDS_LLM_ARCH}'
assert_file_contains "$ai" 'LDS_LLM_ARCH=amd-latest'
assert_file_contains "$ai" 'LDS_AI_MODEL=qwen2.5:3b'
pass "local AI trust boundary, platform and workspace limits are documented"

for stale in   'Scriptomatic/master'   'infocyph/tools:0.23.2'   'infocyph/runner:0.5'   'infocyph/nginx:0.4.1'   'infocyph/apache:0.4.2'   'infocyph/llm-sm:0.03'; do
  if grep -RqsF "$stale" "$ROOT/README.md" "$ROOT/docs" --exclude-dir=plans; then
    fail "user-facing docs contain stale compatibility reference: $stale"
  fi
done
pass "user-facing docs contain no superseded pinned infrastructure defaults"

for subnet in 172.28.0.0 172.29.0.0 172.30.0.0; do
  if grep -RqsF "$subnet" "$ROOT/README.md" "$ROOT/docs" --exclude-dir=plans; then
    fail "user-facing docs contain legacy fixed subnet: $subnet"
  fi
done
pass "user-facing docs contain no legacy fixed subnets"

while IFS= read -r target; do
  [[ -n "$target" ]] || continue
  [[ -f "$ROOT/docs/$target.rst" ]] ||
    fail "docs/index.rst references missing page: $target.rst"
done < <(
  awk '
    /^[[:space:]]{3}[A-Za-z0-9_./-]+$/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line !~ /^:/) print line
    }
  ' "$index"
)
pass "documentation toctree targets exist"


help_md="$("$ROOT/lds" help --markdown)"
for required in   'lds profiles add <profile...>'   'lds support trace <domain>'   'lds support bundle [--redact|--full] [output.zip]'   'lds cli <container> [cmd...]'   'lds run shell|ps|logs|stop|rm|open'   'MongoDB:'   'Elasticsearch:'; do
  assert_contains "$help_md" "$required"
done
pass "embedded CLI help covers documented command groups"


for stale in LDS_TOOLS_IMAGE LDS_RUNNER_IMAGE LDS_NGINX_IMAGE LDS_APACHE_IMAGE; do
  if grep -RqsF "$stale" "$ROOT/README.md" "$ROOT/docs" --exclude-dir=plans; then
    fail "user-facing docs expose obsolete fixed-image variable: $stale"
  fi
done
assert_file_contains "$ai" 'There are no tracked ``ai-*.yaml`` files'
pass "docs reflect fixed infrastructure images and ephemeral AI overrides"
