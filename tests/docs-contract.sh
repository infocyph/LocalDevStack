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
conversion="$ROOT/docs/guides/conversion.rst"
ops="$ROOT/docs/guides/operations-and-support.rst"
runner="$ROOT/docs/guides/ad-hoc-runner.rst"
notify="$ROOT/docs/guides/notifications.rst"
secrets="$ROOT/docs/guides/secrets-sops-age.rst"
cli="$ROOT/docs/reference/cli.rst"

for file in "$index" "$readme" "$quick" "$arch" "$profiles" "$storage" "$domain" "$tls" "$ai" "$databases" "$conversion" "$ops" "$runner" "$notify" "$secrets" "$cli"; do
  assert_file "$file"
done

assert_file_contains "$index" 'guides/local-ai'
assert_file_contains "$index" 'guides/databases-and-clients'
assert_file_contains "$index" 'guides/conversion'
assert_file_contains "$conversion" 'lds convert docs README.md README.html'
assert_file_contains "$conversion" 'lds convert docs --list-output-formats'
assert_file_contains "$conversion" 'lds convert image photo.jpg photo.png'
assert_file_contains "$conversion" 'lds convert image --formats'
assert_file_contains "$conversion" 'no Docker socket'
assert_file_contains "$cli" 'lds convert docs [--force] <input> <output>'
assert_file_contains "$cli" 'lds convert image [--force] <input> <output>'
assert_file_contains "$quick" 'lds convert docs README.md README.html'
assert_file_contains "$quick" 'lds convert image photo.jpg photo.webp'
assert_file_contains "$readme" 'lds convert docs docs/guide.rst guide.docx --toc'
assert_file_contains "$readme" 'lds convert image animation.gif animation.webp'
assert_file_contains "$readme" 'lds tools gitx status'
assert_file_contains "$readme" 'lds tools sqlitex --db app.db tables'
assert_file_contains "$readme" 'cat app.log | lds tools chromacat --log'
assert_file_contains "$quick" 'lds tools list'
assert_file_contains "$cli" 'lds tools <tool> [args...]'
assert_file_contains "$cli" 'lds tools run <tool> [args...]'
assert_file_contains "$cli" 'Docker socket'
assert_file_contains "$cli" 'privileged workstation context'
assert_file_contains "$readme" 'not a sandbox'
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
assert_file_contains "$arch" 'lds shell'
assert_file_contains "$arch" 'utility:tools'
assert_file_contains "$quick" 'lds shell'
assert_file_contains "$domain" 'lds shell project.localhost'
assert_file_contains "$domain" 'lds shell service:php84'
assert_file_contains "$ops" 'lds shell service:nginx -- nginx -t'
assert_file_contains "$secrets" 'lds shell tools'
assert_file_contains "$databases" 'lds shell service:postgres'
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

assert_file_contains "$ai" 'http://llm:11434/v1'
assert_file_contains "$ai" 'https://llm.localhost/v1'
assert_file_contains "$ai" 'http://127.0.0.1:11434/v1'
assert_file_contains "$ai" 'llm-fastflow'
assert_file_contains "$ai" 'llm-ollama'
assert_file_contains "$ai" 'mutually exclusive'
assert_file_contains "$ai" 'qwen3.5:9b'
assert_file_contains "$ai" 'qwen3.5:9b'
assert_file_contains "$ai" 'npu             -> http://llm-fastflow:11434/v1'
assert_file_contains "$ai" 'cpu|nvidia|amd  -> http://llm-ollama:11434/v1'
assert_file_contains "$ai" 'FLM_SERVE_PORT=11434'
assert_file_contains "$ai" '/dev/accel/accel0'
assert_file_contains "$ai" 'LLMFastFlowModels'
assert_file_contains "$ai" 'LLMModels'
assert_file_contains "$ai" 'no Docker socket'
assert_file_contains "$ai" 'no project/repository bind mount'
assert_file_contains "$ai" 'model-generated shell commands'
assert_file_contains "$ai" 'docker/compose/companion.yaml'
assert_file_contains "$ai" 'docker/.runtime/'
assert_file_contains "$ai" 'lds llm runtime npu'
assert_file_contains "$ai" 'lds logs llm'
assert_file_contains "$ai" 'lds shell service:llm-fastflow'
assert_file_contains "$ai" 'lds shell service:llm-ollama'
assert_file_contains "$cli" 'lds restart llm'
assert_file_contains "$cli" 'lds exec llm'
assert_file_contains "$cli" 'lds rebuild llm'
assert_file_contains "$cli" 'does not rewrite logical'
assert_file_contains "$cli" 'service:llm-fastflow'
assert_file_contains "$cli" 'service:llm-ollama'
assert_file_contains "$ai" 'backend=lds-fastflow'
assert_file_contains "$ai" 'backend=lds-ollama'
assert_file_contains "$ai" 'extra_body={"think": false}'
assert_file_contains "$ai" 'reasoning_effort=none'
assert_file_contains "$ai" 'lds llm think'
assert_file_contains "$ai" 'LDS_AI_THINK'
assert_file_contains "$ai" 'extracts code first with ``--code-only --no-cluster``'
assert_file_contains "$ai" '.md .markdown .rst .yaml .yml .json .toml .ini .cfg'
assert_file_contains "$ai" 'LDS_GRAPHIFY_DOCSTRUCT'
assert_file_contains "$ai" 'LDS_GRAPHIFY_DOC_REVIEW'
assert_file_contains "$ai" '--token-budget 3000'
assert_file_contains "$ai" 'cluster-only --no-label --no-viz'
assert_file_contains "$ai" 'retries one malformed structured response once'
assert_file_contains "$cli" 'cluster-only --no-label --no-viz'
assert_file_contains "$ai" 'There is no LocalDevStack Graphify HTTP proxy or Python compatibility adapter.'
assert_file_contains "$ai" 'Graphify'
assert_file_contains "$ai" 'docstruct'
assert_file_contains "$ai" 'think'
assert_file_contains "$ai" 'reasoning_effort'
if grep -RqsF 'LDS_LLM_ARCH' "$ROOT/README.md" "$ROOT/docs" --exclude-dir=plans; then
  fail "user-facing docs expose removed LDS_LLM_ARCH setting"
fi
assert_file_contains "$profiles" 'LDS_AI_RUNTIME=<optional explicit cpu|nvidia|amd|npu>'
assert_file_contains "$profiles" 'llm-fastflow:11434'
assert_file_contains "$profiles" 'llm-ollama:11434'
assert_file_contains "$profiles" 'infocyph/llm-fastflow:latest'
assert_file_contains "$profiles" 'LLM_OLLAMA_ALLOW_LARGE_INPUT=0'
assert_file_contains "$profiles" 'LLM_FASTFLOW_ALLOW_LARGE_INPUT=0'
assert_file_contains "$readme" 'lds llm ask "Explain dependency injection briefly"'
assert_file_contains "$readme" 'infocyph/llm-fastflow:latest'
assert_file_contains "$readme" 'https://llm.localhost'
pass "local AI common identity, mutually exclusive providers, trust boundary, and runtime defaults are documented"

for stale in   'Scriptomatic/master'   'infocyph/tools:0.23.2'   'infocyph/runner:0.5'   'infocyph/nginx:0.4.1'   'infocyph/apache:0.4.2'   'infocyph/llm-ollama:0.03'; do
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
for required in   'lds profiles add <profile...>'   'lds support trace <domain>'   'lds support bundle [--redact|--full] [output.zip]'   'lds shell <target> [--] <command> [args...]'   'lds shell <target> --shell <shell-expression>'   'lds cli <service|container> [--] [command...]'   'lds core [domain|service|container] [--] [command...]'   'lds stack exec <service> [--] [command...]'   'lds tools list'   'lds tools <tool> [args...]'   'lds tools run <tool> [args...]'   'lds tools exec [--] <command> [args...]'   'lds tools shell-exec <shell-expression>'   'lds run shell|ps|logs|stop|rm|open'   'MongoDB:'   'Elasticsearch:'; do
  assert_contains "$help_md" "$required"
done
pass "embedded CLI help covers documented command groups"

assert_file_contains "$cli" 'Execution and Shells'
assert_file_contains "$cli" 'lds shell <target> [--] <command> [args...]'
assert_file_contains "$cli" 'Applications'
assert_file_contains "$cli" 'domain:project.localhost'
assert_file_contains "$cli" 'utility:tools'
assert_file_contains "$cli" 'Image'
assert_file_contains "$cli" 'lds core [domain|service|container] [--] [command...]'
assert_file_contains "$cli" 'lds cli <service|container> [--] [command...]'
assert_file_contains "$cli" 'lds stack exec <service> [--] [command...]'
assert_file_contains "$cli" 'lds tools list'
assert_file_contains "$cli" 'lds tools <tool> [args...]'
assert_file_contains "$cli" 'lds tools run <tool> [args...]'
assert_file_contains "$cli" 'lds tools exec [--] <command> [args...]'
assert_file_contains "$cli" 'lds tools shell-exec <shell-expression>'
assert_file_contains "$cli" 'preserve argv exactly'
assert_file_contains "$cli" 'require a real TTY'
assert_file_contains "$readme" '## Execution and shells'
assert_file_contains "$readme" 'lds shell'
assert_file_contains "$readme" 'lds shell project.localhost -- php artisan about'
assert_file_contains "$readme" 'lds shell php84 -- php -v'
assert_file_contains "$readme" 'lds shell tools --interactive lazydocker'
assert_file_contains "$readme" 'utility:tools'
assert_contains "$help_md" 'utility:tools'
if grep -Fq 'lds core project.localhost' "$domain"; then
  fail "domain guide still teaches lds core as the primary domain shell"
fi
if grep -Fq 'lds cli <container>' "$domain"; then
  fail "domain guide still teaches lds cli as the primary container shell"
fi
pass "execution-surface docs match the shared Core/CLI contract"


for stale in LDS_TOOLS_IMAGE LDS_RUNNER_IMAGE LDS_NGINX_IMAGE LDS_APACHE_IMAGE; do
  if grep -RqsF "$stale" "$ROOT/README.md" "$ROOT/docs" --exclude-dir=plans; then
    fail "user-facing docs expose obsolete fixed-image variable: $stale"
  fi
done
assert_file_contains "$ai" 'Both provider definitions live in ``docker/compose/companion.yaml``'
pass "docs reflect fixed infrastructure images and ephemeral AI overrides"

if [[ -d "$ROOT/docs/plans" ]] && find "$ROOT/docs/plans" -type f -print -quit | grep -q .; then
  fail "completed planning artifact remains under docs/plans"
fi
pass "completed LocalDevStack planning artifacts are retired"
