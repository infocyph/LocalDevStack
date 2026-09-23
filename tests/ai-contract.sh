#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

image="lds-fake-llm:ci"
container="lds-fake-llm-ci"
network="lds-ai-ci"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$network" >/dev/null
docker build -q -t "$image" "$ROOT/tests/fixtures/fake-ollama" >/dev/null
docker run -d   --name "$container"   --network "$network"   --network-alias llm   --network-alias llm-ollama   "$image" >/dev/null

for _ in {1..20}; do
  if docker exec "$container" python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:11434/v1/models", timeout=1).read()' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

models="$(
  docker exec "$container" python -c     'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:11434/v1/models", timeout=2).read().decode())'
)"
assert_contains "$models" "qwen3.5:9b"

tags="$(
  docker exec "$container" python -c     'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=2).read().decode())'
)"
assert_contains "$tags" "qwen3.5:9b"
pass "fake provider exposes common OpenAI API plus Ollama-native compatibility"

docker pull infocyph/tools:latest >/dev/null
provider_status="$(
  docker run --rm --network "$network"     --entrypoint askai     -e LDS_AI_ENABLED=1     -e LDS_AI_PROVIDER=llm     -e LDS_AI_URL=http://llm:11434     -e LDS_AI_MODEL=qwen3.5:9b     infocyph/tools:latest --status
)"
assert_contains "$provider_status" "provider=llm"
assert_contains "$provider_status" "available=1"
assert_contains "$provider_status" "model=qwen3.5:9b"
pass "latest Tools reaches the common LocalDevStack llm contract"

[[ ! -e "$ROOT/docker/compose/ai.yaml" ]] || fail "base AI service must remain consolidated into companion.yaml"
if find "$ROOT/docker/compose" -maxdepth 1 -type f -name 'ai-*.yaml' -print -quit | grep -q .; then
  fail "AI-specific Compose overlays must be generated ephemerally"
fi

assert_file_contains "$ROOT/docker/compose/companion.yaml" 'image: infocyph/llm-ollama:latest'
assert_file_contains "$ROOT/lib/compose.sh" 'image: infocyph/llm-ollama:amd-latest'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'image: infocyph/llm-fastflow:latest'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'profiles: ["${LDS_AI_OLLAMA_PROFILE:-ai}"]'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'profiles: ["${LDS_AI_FASTFLOW_PROFILE:-__lds-ai-disabled-fastflow}"]'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'aliases: [llm]'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'lds_llm:/root/.ollama'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'lds_llm_fastflow:/models'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LLM_OLLAMA_MODEL=${LDS_AI_MODEL:-qwen3.5:9b}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LLM_FASTFLOW_MODEL=${LDS_AI_MODEL:-qwen3.5:9b}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LLM_THINK=${LDS_AI_THINK:-}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LDS_AI_THINK=${LDS_AI_THINK:-}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'FLM_SERVE_PORT=11434'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LDS_AI_PROVIDER=${LDS_AI_PROVIDER:-llm}'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LDS_AI_URL=${LDS_AI_URL:-http://llm:11434}'
assert_file_contains "$ROOT/docker/compose/http.yaml" 'LLM_PROXY_TIMEOUT_SECONDS=${LDS_AI_TIMEOUT:-1800}'
assert_file_contains "$ROOT/docker/compose/http.yaml" '"127.0.0.1:11434:11434"'
pass "companion defines mutually exclusive provider services behind common llm alias"

assert_file_contains "$ROOT/lib/compose.sh" 'LDS_AI_PROVIDER=llm'
assert_file_contains "$ROOT/lib/compose.sh" 'LDS_AI_URL=http://llm:11434'
assert_file_contains "$ROOT/lib/compose.sh" 'ollama_profile=__lds-ai-disabled-ollama'
assert_file_contains "$ROOT/lib/compose.sh" 'fastflow_profile=ai'
assert_file_contains "$ROOT/lib/compose.sh" 'ollama_profile=ai'
assert_file_contains "$ROOT/lib/compose.sh" 'fastflow_profile=__lds-ai-disabled-fastflow'
assert_file_contains "$ROOT/lib/compose.sh" "'    gpus: all'"
assert_file_contains "$ROOT/lib/compose.sh" "'      - /dev/kfd:/dev/kfd'"
assert_file_contains "$ROOT/lib/compose.sh" "'      - /dev/dri:/dev/dri'"
pass "Compose wrapper selects exactly one provider and augments only Ollama GPU modes"

if grep -R -nF 'LDS_LLM_ARCH' "$ROOT/lib" "$ROOT/docker/compose" "$ROOT/docker/catalog"; then
  fail "obsolete LDS_LLM_ARCH must not remain in active LocalDevStack code or catalog"
fi
pass "LLM image tags are direct and LDS_LLM_ARCH is removed"

assert_file_contains "$ROOT/lib/ai.sh" 'http://llm.localhost:11434/v1'
assert_file_contains "$ROOT/lib/ai.sh" '/v1/models'
assert_file_contains "$ROOT/lib/ai.sh" 'index($model) != null'
assert_file_contains "$ROOT/lib/ai.sh" 'Run: lds llm pull $model'
assert_file_contains "$ROOT/lib/ai.sh" 'ai_service_for_runtime'
assert_file_contains "$ROOT/lib/ai.sh" 'llm-fastflow'
assert_file_contains "$ROOT/lib/ai.sh" 'llm-ollama'
assert_file_contains "$ROOT/lib/ai.sh" 'fastflow) printf '\''%s'\'' openai'
assert_file_contains "$ROOT/lib/ai.sh" 'ollama) printf '\''%s'\'' ollama'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_TOKEN_BUDGET:-3000'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_MAX_CONCURRENCY:-1'
assert_file_contains "$ROOT/lib/ai.sh" 'lds-fastflow'
assert_file_contains "$ROOT/lib/ai.sh" 'lds-ollama'
assert_file_contains "$ROOT/lib/ai.sh" 'extra_body: {think: false}'
assert_file_contains "$ROOT/lib/ai.sh" 'reasoning_effort: "none"'
assert_file_contains "$ROOT/lib/ai.sh" 'backend="$(_graphify_write_local_provider "$provider_dir" "$provider" "$base_url"'
assert_file_contains "$ROOT/lib/ai.sh" 'export GRAPHIFY_MAX_OUTPUT_TOKENS="$structured_output_tokens"'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_OUTPUT_TOKENS:-8192'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_MIN_VERSION:-0.9.65'
assert_file_contains "$ROOT/lib/ai.sh" 'manifest.json'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_SDK_RETRIES:-0'
assert_file_contains "$ROOT/lib/ai.sh" 'export GRAPHIFY_MAX_RETRIES="$graphify_sdk_retries"'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_MAX_RETRY_DEPTH:-2'
assert_file_contains "$ROOT/lib/ai.sh" 'export GRAPHIFY_MAX_RETRY_DEPTH="$graphify_retry_depth"'
assert_file_contains "$ROOT/lib/ai.sh" 'existing graph detected; using Graphify incremental update (changed files only)'
assert_file_contains "$ROOT/lib/ai.sh" 'existing graph detected; --force requested, performing a full rebuild'
assert_file_contains "$ROOT/lib/ai.sh" 'no graph detected; bootstrapping code-first before semantic enrichment'
assert_file_contains "$ROOT/lib/ai.sh" 'phase 1/2: extracting code structure and clustering the structural graph'
assert_file_contains "$ROOT/lib/ai.sh" 'phase 2/2: enriching the existing graph with semantic files'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_THINK:-off'
assert_file_contains "$ROOT/lib/ai.sh" 'llm think <auto|on|off>'
pass "LLM CLI and Graphify resolve through provider-aware common endpoint"

(
  set -euo pipefail
  need_bin() { :; }
  die() { return 1; }
  curl() {
    printf '%s\n' '{"object":"list","data":[{"id":"qwen3.5:9b"},{"id":"qwen3.5:9b"}]}'
  }
  # shellcheck source=lib/ai.sh
  source "$ROOT/lib/ai.sh"

  _graphify_local_model_preflight qwen3.5:9b ||
    fail "Graphify rejected the Ollama default through common model catalog"
  _graphify_local_model_preflight qwen3.5:9b ||
    fail "Graphify rejected the FastFlow default through common model catalog"
  if _graphify_local_model_preflight missing-model; then
    fail "Graphify accepted a model absent from the common model catalog"
  fi
)
pass "Graphify validates either provider model through /v1/models"

(
  set -euo pipefail
  die() { return 1; }
  # shellcheck source=lib/ai.sh
  source "$ROOT/lib/ai.sh"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/project/graphify-out"

  if _graphify_has_graph "$tmp/project"; then
    fail "Graphify graph baseline detected before graph.json exists"
  fi
  if _graphify_has_incremental_state "$tmp/project"; then
    fail "Graphify incremental state accepted without graph/manifest pair"
  fi
  : >"$tmp/project/graphify-out/graph.json"
  _graphify_has_graph "$tmp/project" ||
    fail "Graphify graph baseline was not detected from graph.json"
  if _graphify_has_incremental_state "$tmp/project"; then
    fail "Graphify incremental state accepted without manifest"
  fi
  : >"$tmp/project/graphify-out/manifest.json"
  _graphify_has_incremental_state "$tmp/project" ||
    fail "Graphify incremental state rejected complete graph/manifest pair"

  cat >"$tmp/graphify-new" <<'SH'
#!/usr/bin/env sh
printf '%s\n' 'graphify 0.9.65'
SH
  cat >"$tmp/graphify-old" <<'SH'
#!/usr/bin/env sh
printf '%s\n' 'graphify 0.9.64'
SH
  chmod +x "$tmp/graphify-new" "$tmp/graphify-old"

  _graphify_version_preflight "$tmp/graphify-new" ||
    fail "Graphify minimum compatible version was rejected"
  if _graphify_version_preflight "$tmp/graphify-old"; then
    fail "Graphify version below compatibility floor was accepted"
  fi
)
pass "Graphify incremental state and minimum-version contracts are enforced"

(
  set -euo pipefail
  # shellcheck source=lib/ai.sh
  source "$ROOT/lib/ai.sh"

  [[ "$(_graphify_backend_for_provider fastflow)" == openai ]] ||
    fail "FastFlow Graphify backend did not resolve to openai"
  [[ "$(_graphify_backend_for_provider ollama)" == ollama ]] ||
    fail "Ollama Graphify backend did not resolve to ollama"
  if _graphify_backend_for_provider unknown >/dev/null 2>&1; then
    fail "Unknown LLM provider unexpectedly resolved a Graphify backend"
  fi
)
pass "Graphify backend selection follows active LLM provider"

(
  set -euo pipefail
  # shellcheck source=lib/ai.sh
  source "$ROOT/lib/ai.sh"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  [[ "$(_graphify_write_local_provider "$tmp" fastflow http://llm.localhost:11434/v1 qwen3.5:9b 4000 off)" == lds-fastflow ]] ||
    fail "FastFlow local Graphify provider name drifted"
  jq -e '."lds-fastflow".base_url == "http://llm.localhost:11434/v1" and ."lds-fastflow".max_tokens == 8192 and ."lds-fastflow".extra_body.think == false and (."lds-fastflow" | has("reasoning_effort") | not)' "$tmp/.graphify/providers.json" >/dev/null ||
    fail "FastFlow local Graphify provider must use the direct endpoint, output cap and no-thinking"

  [[ "$(_graphify_write_local_provider "$tmp" fastflow http://llm.localhost:11434/v1 qwen3.5:9b 4000 on)" == lds-fastflow ]] ||
    fail "FastFlow local Graphify thinking-on provider name drifted"
  jq -e '."lds-fastflow".extra_body.think == true and ."lds-fastflow".reasoning_effort == "high"' "$tmp/.graphify/providers.json" >/dev/null ||
    fail "FastFlow Graphify thinking-on override did not map to think=true/high"

  [[ "$(_graphify_write_local_provider "$tmp" fastflow http://llm.localhost:11434/v1 qwen3.5:9b 4000 auto)" == lds-fastflow ]] ||
    fail "FastFlow local Graphify auto provider name drifted"
  jq -e '(."lds-fastflow" | has("extra_body") | not) and (."lds-fastflow" | has("reasoning_effort") | not)' "$tmp/.graphify/providers.json" >/dev/null ||
    fail "FastFlow Graphify auto override must omit thinking controls"

  [[ "$(_graphify_write_local_provider "$tmp" ollama http://llm.localhost:11434/v1 qwen3.5:9b 4000)" == lds-ollama ]] ||
    fail "Ollama local Graphify provider name drifted"
  jq -e '."lds-ollama".base_url == "http://llm.localhost:11434/v1" and ."lds-ollama".max_tokens == 8192 and ."lds-ollama".reasoning_effort == "none" and ."lds-ollama".extra_body.options.num_ctx >= 16384' "$tmp/.graphify/providers.json" >/dev/null ||
    fail "Ollama local Graphify provider must use the direct endpoint, output cap, no-thinking and context headroom"
)
pass "Graphify local providers use direct OpenAI-compatible endpoints"


(
  set -euo pipefail
  # shellcheck source=lib/services.sh
  source "$ROOT/lib/services.sh"

  normalize_service() { printf '%s' "${1,,}"; }
  docker() { return 1; }

  __test_runtime=npu
  effective_ai_runtime() { printf '%s' "$__test_runtime"; }
  ai_service_for_runtime() {
    case "${1,,}" in
      npu) printf '%s' llm-fastflow ;;
      *) printf '%s' llm-ollama ;;
    esac
  }
  compose_service_exists() {
    case "$1" in
      llm-fastflow|llm-ollama) return 0 ;;
      *) return 1 ;;
    esac
  }

  [[ "$(resolve_service llm)" == "llm-fastflow" ]] ||
    fail "common llm alias did not resolve FastFlow for NPU runtime"
  __test_runtime=cpu
  [[ "$(resolve_service llm)" == "llm-ollama" ]] ||
    fail "common llm alias did not resolve Ollama for CPU runtime"
)
pass "generic service commands resolve llm to the active provider"
