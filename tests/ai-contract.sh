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
assert_contains "$models" "qwen3:14b"

tags="$(
  docker exec "$container" python -c     'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=2).read().decode())'
)"
assert_contains "$tags" "qwen3:14b"
pass "fake provider exposes common OpenAI API plus Ollama-native compatibility"

docker pull infocyph/tools:latest >/dev/null
provider_status="$(
  docker run --rm --network "$network"     --entrypoint askai     -e LDS_AI_ENABLED=1     -e LDS_AI_PROVIDER=llm     -e LDS_AI_URL=http://llm:11434     -e LDS_AI_MODEL=qwen3:14b     infocyph/tools:latest --status
)"
assert_contains "$provider_status" "provider=llm"
assert_contains "$provider_status" "available=1"
assert_contains "$provider_status" "model=qwen3:14b"
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
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'LLM_OLLAMA_MODEL=${LDS_AI_MODEL:-qwen3:14b}'
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
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_TOKEN_BUDGET:-4000'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_MAX_CONCURRENCY:-1'
assert_file_contains "$ROOT/lib/ai.sh" 'lds-fastflow'
assert_file_contains "$ROOT/lib/ai.sh" 'lds-ollama'
assert_file_contains "$ROOT/lib/ai.sh" 'extra_body: {think: false}'
assert_file_contains "$ROOT/lib/ai.sh" 'reasoning_effort: "none"'
assert_file_contains "$ROOT/lib/ai.sh" 'graphify-diagnostic-proxy.py'
assert_file_contains "$ROOT/lib/ai.sh" 'http://127.0.0.1:${proxy_port}/v1'
assert_file_contains "$ROOT/lib/ai.sh" '--provider "$provider"'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_DIAGNOSTICS:-0'
assert_file_contains "$ROOT/lib/ai.sh" '--diagnostics "$diagnostic_mode"'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_THINK:-off'
assert_file_contains "$ROOT/lib/ai.sh" 'lds-graphify-diagnostics.jsonl'
assert_file_contains "$ROOT/lib/ai.sh" 'llm think <auto|on|off>'
pass "LLM CLI and Graphify resolve through provider-aware common endpoint"

(
  set -euo pipefail
  need_bin() { :; }
  die() { return 1; }
  curl() {
    printf '%s\n' '{"object":"list","data":[{"id":"qwen3:14b"},{"id":"qwen3.5:9b"}]}'
  }
  # shellcheck source=lib/ai.sh
  source "$ROOT/lib/ai.sh"

  _graphify_local_model_preflight qwen3:14b ||
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
  jq -e '."lds-fastflow".extra_body.think == false and (."lds-fastflow" | has("reasoning_effort") | not)' "$tmp/.graphify/providers.json" >/dev/null ||
    fail "FastFlow local Graphify provider must default to no-thinking"

  [[ "$(_graphify_write_local_provider "$tmp" fastflow http://llm.localhost:11434/v1 qwen3.5:9b 4000 on)" == lds-fastflow ]] ||
    fail "FastFlow local Graphify thinking-on provider name drifted"
  jq -e '."lds-fastflow".extra_body.think == true and ."lds-fastflow".reasoning_effort == "high"' "$tmp/.graphify/providers.json" >/dev/null ||
    fail "FastFlow Graphify thinking-on override did not map to think=true/high"

  [[ "$(_graphify_write_local_provider "$tmp" fastflow http://llm.localhost:11434/v1 qwen3.5:9b 4000 auto)" == lds-fastflow ]] ||
    fail "FastFlow local Graphify auto provider name drifted"
  jq -e '(."lds-fastflow" | has("extra_body") | not) and (."lds-fastflow" | has("reasoning_effort") | not)' "$tmp/.graphify/providers.json" >/dev/null ||
    fail "FastFlow Graphify auto override must omit thinking controls"

  [[ "$(_graphify_write_local_provider "$tmp" ollama http://llm.localhost:11434/v1 qwen3:14b 4000)" == lds-ollama ]] ||
    fail "Ollama local Graphify provider name drifted"
  jq -e '."lds-ollama".reasoning_effort == "none" and ."lds-ollama".extra_body.options.num_ctx >= 8192' "$tmp/.graphify/providers.json" >/dev/null ||
    fail "Ollama local Graphify provider must disable thinking and retain context headroom"
)
pass "Graphify local providers enforce structured no-thinking contracts"

python3 -m py_compile "$ROOT/scripts/graphify-diagnostic-proxy.py"
python3 - "$ROOT/scripts/graphify-diagnostic-proxy.py" <<'PY'
import importlib.util
import json
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("lds_graphify_diagnostic_proxy", path)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)

suspect, reason = module.classify_graph_content('{"nodes":[],"edges":[],"hyperedges":[]}')
assert suspect and reason == "valid but empty graph fragment"

suspect, reason = module.classify_graph_content('{"nodes":["A","B"],"edges":[]}')
assert suspect and "no usable object entries" in reason

suspect, _ = module.classify_graph_content(
    '{"nodes":[{"id":"a","label":"A"}],"edges":[],"hyperedges":[]}'
)
assert not suspect

fence = chr(96) * 3
suspect, _ = module.classify_graph_content(
    "answer follows\n" + fence + "json\n" +
    '{"nodes":[{"id":"a"}],"edges":[]}' + "\n" + fence
)
assert not suspect

suspect, reason = module.classify_graph_content("I found nothing useful in these documents.")
assert suspect and "not parseable" in reason

suspect, reason = module.classify_graph_content(
    '{"nodes":[{"id":"a","source_file:".github/x.md"}],"edges":[]}'
)
assert suspect and reason == "malformed graph JSON"

assert module.parse_graph_content('{"nodes":[],"edges":[],"hyperedges":[]}') == {
    "nodes": [],
    "edges": [],
    "hyperedges": [],
}
assert module.parse_graph_content('{"nodes":["bad"],"edges":[],"hyperedges":[]}') is None

assert module.parse_graph_content(
    '{"nodes":[{"id":"a"}],"edges":[],"hyperedges":[]}'
) == {
    "nodes": [{"id": "a"}],
    "edges": [],
    "hyperedges": [],
}

body = json.dumps({
    "model": "qwen3.5:9b",
    "messages": [
        {"role": "system", "content": "You are a graphify semantic extraction agent."},
        {"role": "user", "content": "private corpus content"}
    ],
    "think": False,
    "stream": False
}).encode()
metadata = module._request_metadata(body)
assert metadata["_extraction_request"] is True
assert metadata["think"] is False
assert "private corpus content" not in json.dumps(metadata)

recovery = module._build_tool_recovery_request(body)
assert recovery is not None
recovery_json = json.loads(recovery)
assert recovery_json["tools"][0]["function"]["name"] == "submit_graph"
assert recovery_json["tool_choice"] == "auto"
assert recovery_json["think"] is False
assert "STRUCTURED OUTPUT" in recovery_json["messages"][0]["content"]
assert recovery_json["temperature"] == 0
assert recovery_json["max_completion_tokens"] == 4096

assert recovery_json["tools"][0]["function"]["parameters"] == module._GRAPH_SCHEMA
assert "rationale_for" not in module._GRAPH_SCHEMA["properties"]["edges"]["items"]["properties"]["relation"]["enum"]

ollama_body = json.dumps({
    "model": "qwen3:14b",
    "messages": [
        {"role": "system", "content": "You are a graphify semantic extraction agent."},
        {"role": "user", "content": "private corpus content"}
    ],
    "reasoning_effort": "none",
    "stream": False,
    "temperature": 0,
    "options": {"num_ctx": 8192},
}).encode()
ollama_request = module._build_ollama_schema_request(ollama_body)
assert ollama_request is not None
ollama_json = json.loads(ollama_request)
assert ollama_json["reasoning_effort"] == "none"
assert ollama_json["options"]["num_ctx"] == 8192
assert ollama_json["temperature"] == 0
assert ollama_json["max_completion_tokens"] == 4096
assert ollama_json["response_format"]["type"] == "json_schema"
assert ollama_json["response_format"]["json_schema"]["strict"] is True
assert ollama_json["response_format"]["json_schema"]["schema"] == module._GRAPH_SCHEMA

tool_response = {
    "id": "chatcmpl-test",
    "object": "chat.completion",
    "choices": [{
        "index": 0,
        "finish_reason": "tool_calls",
        "message": {
            "role": "assistant",
            "reasoning_content": "private reasoning",
            "content": "<think>private reasoning</think>",
            "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": {
                    "name": "submit_graph",
                    "arguments": json.dumps({
                        "nodes": [{"id": "readme_pathwise", "label": "Pathwise"}],
                        "edges": [],
                        "hyperedges": [],
                    }),
                },
            }],
        },
    }],
    "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30},
}
graph = module._extract_graph_tool_result(json.dumps(tool_response).encode())
assert graph == {
    "nodes": [{"id": "readme_pathwise", "label": "Pathwise"}],
    "edges": [],
    "hyperedges": [],
}

assert module._extract_fastflow_structured_graph(json.dumps(tool_response).encode()) == graph

content_only_response = {
    "choices": [{
        "index": 0,
        "finish_reason": "stop",
        "message": {
            "role": "assistant",
            "content": json.dumps(graph),
        },
    }],
    "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30},
}
assert module._extract_fastflow_structured_graph(
    json.dumps(content_only_response).encode()
) == graph

retry = module._build_tool_recovery_request(body, retry=True)
assert retry is not None
retry_json = json.loads(retry)
assert "previous structured attempt" in retry_json["messages"][0]["content"]
assert retry_json["max_completion_tokens"] == 4096
replacement = module._replace_response_content(json.dumps(tool_response).encode(), graph)
assert replacement is not None
replacement_json = json.loads(replacement)
message = replacement_json["choices"][0]["message"]
assert json.loads(message["content"]) == graph
assert "tool_calls" not in message
assert "reasoning_content" not in message
assert replacement_json["choices"][0]["finish_reason"] == "stop"

string_array_response = json.loads(json.dumps(tool_response))
string_array_response["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] = json.dumps({
    "nodes": json.dumps([{"id": "a"}]),
    "edges": "[]",
    "hyperedges": "[]",
})
assert module._extract_graph_tool_result(json.dumps(string_array_response).encode()) == {
    "nodes": [{"id": "a"}],
    "edges": [],
    "hyperedges": [],
}

empty_tool_response = json.loads(json.dumps(tool_response))
empty_tool_response["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] = json.dumps({
    "nodes": [],
    "edges": [],
    "hyperedges": [],
})
assert module._extract_graph_tool_result(json.dumps(empty_tool_response).encode()) == {
    "nodes": [],
    "edges": [],
    "hyperedges": [],
}
PY
pass "Graphify diagnostic proxy identifies and structurally recovers suspect responses"


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
