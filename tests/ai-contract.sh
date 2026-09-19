#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

image="lds-fake-ollama:ci"
container="lds-fake-ollama-ci"
network="lds-ai-ci"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$network" >/dev/null
docker build -q -t "$image" "$ROOT/tests/fixtures/fake-ollama" >/dev/null
docker run -d --name "$container" --network "$network" --network-alias llm-sm "$image" >/dev/null

for _ in {1..20}; do
  if docker exec "$container" python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=1).read()' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

tags="$(
  docker exec "$container" python -c     'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=2).read().decode())'
)"
assert_contains "$tags" "qwen2.5:3b"

generate="$(
  docker exec "$container" python -c     'import urllib.request; r=urllib.request.Request("http://127.0.0.1:11434/api/generate", data=b"{}", headers={"Content-Type":"application/json"}); print(urllib.request.urlopen(r, timeout=2).read().decode())'
)"
assert_contains "$generate" "LocalDevStack CI"

models="$(
  docker exec "$container" python -c     'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:11434/v1/models", timeout=2).read().decode())'
)"
assert_contains "$models" "qwen2.5:3b"
pass "fake Ollama tags/generate/OpenAI-compatible contracts"

docker pull infocyph/tools:latest >/dev/null
provider_status="$(
  docker run --rm --network "$network"     --entrypoint askai     -e LDS_AI_ENABLED=1     -e LDS_AI_PROVIDER=ollama     -e LDS_AI_URL=http://llm-sm:11434     -e LDS_AI_MODEL=qwen2.5:3b     infocyph/tools:latest --status
)"
assert_contains "$provider_status" "available=1"
assert_contains "$provider_status" "model=qwen2.5:3b"
pass "latest Tools reaches the separate provider contract"

[[ ! -e "$ROOT/docker/compose/ai.yaml" ]] || fail "base AI service must remain consolidated into companion.yaml"
if find "$ROOT/docker/compose" -maxdepth 1 -type f -name 'ai-*.yaml' -print -quit | grep -q .; then
  fail "AI-specific Compose overlays must be generated ephemerally"
fi
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'image: infocyph/llm-sm:${LDS_LLM_ARCH}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'profiles: [ai]'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'lds_llm:/root/.ollama'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LLM_SM_MODEL=${LDS_AI_MODEL:-qwen2.5:3b}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LLM_SM_ATTACHMENT_MAX_BYTES=${LLM_SM_ATTACHMENT_MAX_BYTES:-16777216}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LLM_SM_PDF_MAX_PAGES=${LLM_SM_PDF_MAX_PAGES:-24}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LDS_AI_CONNECT_TIMEOUT=${LDS_AI_CONNECT_TIMEOUT:-2}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LDS_AI_PREFLIGHT_TIMEOUT=${LDS_AI_PREFLIGHT_TIMEOUT:-5}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LDS_AI_TIMEOUT=${LDS_AI_TIMEOUT:-1800}'
assert_file_contains "$ROOT/docker/compose/http.yaml" 'LLM_PROXY_TIMEOUT_SECONDS=${LDS_AI_TIMEOUT:-1800}'
assert_file_contains "$ROOT/lib/compose.sh" "'    gpus: all'"
assert_file_contains "$ROOT/lib/compose.sh" "'      - /dev/kfd:/dev/kfd'"
assert_file_contains "$ROOT/lib/compose.sh" "'      - /dev/dri:/dev/dri'"
assert_file_contains "$ROOT/lib/compose.sh" '"127.0.0.1:%s:11434"'
pass "single companion AI service with ephemeral hardware/port augmentation"
