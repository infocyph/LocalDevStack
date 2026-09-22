#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is required"

for compose_file in "$ROOT"/docker/compose/*.yaml; do
  if awk '
    /^    volumes:[[:space:]]*$/ { in_service_volumes=1; next }
    in_service_volumes && /^      - / {
      entry=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", entry)
      if (entry ~ /^["'\''"]/ ) exit 1
      next
    }
    in_service_volumes { in_service_volumes=0 }
  ' "$compose_file"; then
    :
  else
    fail "service volume mounts must use unquoted short-syntax scalars: $compose_file"
  fi
done
pass "service volume mounts use one unquoted short-syntax style"

release_env="$ROOT/docker/release.env"
user_env="$ROOT/docker/.env"
backup_env=""
had_user_env=0

if [[ -e "$user_env" ]]; then
  had_user_env=1
  backup_env="$(mktemp)"
  cp "$user_env" "$backup_env"
fi

cleanup() {
  if ((had_user_env)); then
    cp "$backup_env" "$user_env"
    rm -f "$backup_env"
  else
    rm -f "$user_env"
  fi
}
trap cleanup EXIT

cat >"$user_env" <<EOF
TZ=UTC
USER=$(id -un)
UID=$(id -u)
GID=$(id -g)
PROJECT_DIR=$ROOT
EOF

compose=(docker compose
  --project-directory "$ROOT"
  -f "$ROOT/docker/compose/main.yaml"
  --env-file "$release_env"
  --env-file "$user_env"
)

render() {
  local name="$1"
  shift
  printf 'Validating Compose matrix: %s\n' "$name"
  "${compose[@]}" "$@" config --quiet
}

render core
render mysql --profile mysql
render mariadb --profile mariadb
render postgresql --profile postgresql
render mongodb --profile mongodb
render redis --profile redis
render elasticsearch --profile elasticsearch
render elasticsearch-filebeat --profile elasticsearch --profile filebeat
render ai --profile ai

resolved="$("${compose[@]}" --profile mysql config)"
assert_contains "$resolved" "server-tools:"
assert_contains "$resolved" "nginx:"
assert_contains "$resolved" "mysql:"
assert_contains "$resolved" "cloudbeaver:"
assert_contains "$resolved" "image: infocyph/tools:latest"
assert_contains "$resolved" "image: infocyph/runner:latest"
assert_contains "$resolved" "image: infocyph/nginx:latest"
if grep -Eq 'ipv4_address:|172\\.28\\.0\\.|172\\.29\\.0\\.|172\\.30\\.0\\.' <<<"$resolved"; then
  fail "resolved Compose config still contains fixed LocalDevStack addresses"
fi
assert_contains "$resolved" "name: Frontend"
assert_contains "$resolved" "name: Backend"
assert_contains "$resolved" "name: DataStore"
pass "release compatibility defaults and dynamic networks resolve"

postgres_json="$("${compose[@]}" --profile postgresql config --format json)"
python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["services"]["postgres"]["image"] == "postgres:alpine"
' <<<"$postgres_json"
pass "PostgreSQL follows moving Alpine policy"

elastic_json="$("${compose[@]}" --profile elasticsearch --profile filebeat config --format json)"
python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["services"]["elasticsearch"]["image"] == "docker.elastic.co/elasticsearch/elasticsearch:9.5.4"
assert d["services"]["kibana"]["image"] == "docker.elastic.co/kibana/kibana:9.5.4"
assert d["services"]["filebeat"]["image"] == "docker.elastic.co/beats/filebeat:9.5.4"
' <<<"$elastic_json"
pass "Elastic stack uses aligned current-stable tags because latest is unsupported"

printf '%s\n' 'LDS_TOOLS_IMAGE=example.invalid/tools:ignored' >>"$user_env"
fixed_images="$("${compose[@]}" config)"
assert_contains "$fixed_images" "image: infocyph/tools:latest"
if grep -Fq 'example.invalid/tools' <<<"$fixed_images"; then
  fail "fixed infrastructure images must not be user-overridable"
fi
pass "fixed infrastructure images are declared directly in Compose"

core_json="$("${compose[@]}" config --format json)"
python3 -c '
import json,sys
d=json.load(sys.stdin)
assert "apache" in d.get("services", {})
assert "llm-ollama" not in d.get("services", {})
assert d["volumes"]["lds_tools_state"]["name"] == "ToolsState"
tools=d["services"]["server-tools"]
targets={v["target"] for v in tools["volumes"]}
assert "/etc/share/state" in targets
' <<<"$core_json"
pass "Apache remains compatibility-safe for CLI/Admin hosts, AI stays optional, and Tools state is persistent"

ai_json="$("${compose[@]}" --profile ai config --format json)"
python3 -c '
import json,sys
d=json.load(sys.stdin)
services=d["services"]
assert "llm-ollama" in services
assert "llm-fastflow" not in services
s=services["llm-ollama"]
assert s["image"] == "infocyph/llm-ollama:latest"
assert s["container_name"] == "LLM_OLLAMA"
assert not s.get("ports")
assert set(s["networks"]) == {"frontend","backend"}
assert {v["target"] for v in s["volumes"]} == {"/root/.ollama"}
assert d["volumes"]["lds_llm"]["name"] == "LLMModels"
env=s["environment"]
assert env["LLM_OLLAMA_MODEL"] == "qwen3.5:9b"
assert env["OLLAMA_NO_CLOUD"] == "1"
tools=services["server-tools"]["environment"]
assert tools["LDS_AI_ENABLED"] == "auto"
assert tools["LDS_AI_PROVIDER"] == "llm"
assert tools["LDS_AI_URL"] == "http://llm:11434"
assert tools["LDS_AI_MODEL"] == "qwen3.5:9b"
nginx=services["nginx"]
assert nginx["environment"]["LLM_PROXY_TIMEOUT_SECONDS"] == "1800"
native=[p for p in nginx.get("ports", []) if int(p["target"]) == 11434]
assert len(native) == 1
assert native[0]["host_ip"] == "127.0.0.1"
assert int(native[0]["published"]) == 11434
' <<<"$ai_json"
pass "bare Compose AI profile keeps Ollama compatibility fallback behind common llm identity"

printf '%s\n' 'LDS_AI_MODEL=qwen2.5:1.5b' 'LLM_OLLAMA_PDF_MAX_PAGES=12' 'LLM_OLLAMA_SYSTEM=Answer briefly.' 'LDS_AI_TIMEOUT=2400' 'LDS_AI_IGPU_ENABLE=1' >>"$user_env"
ai_override_json="$("${compose[@]}" --profile ai config --format json)"
python3 -c '
import json,sys
d=json.load(sys.stdin)
llm=d["services"]["llm-ollama"]["environment"]
assert llm["LLM_OLLAMA_MODEL"] == "qwen2.5:1.5b"
assert llm["LLM_OLLAMA_PDF_MAX_PAGES"] == "12"
assert llm["LLM_OLLAMA_SYSTEM"] == "Answer briefly."
assert llm["OLLAMA_IGPU_ENABLE"] == "1"
tools=d["services"]["server-tools"]["environment"]
assert tools["LDS_AI_PROVIDER"] == "llm"
assert tools["LDS_AI_URL"] == "http://llm:11434"
assert tools["LDS_AI_TIMEOUT"] == "2400"
nginx=d["services"]["nginx"]["environment"]
assert nginx["LLM_PROXY_TIMEOUT_SECONDS"] == "2400"
' <<<"$ai_override_json"
pass "LocalDevStack forwards common Tools routing and Ollama-specific generation options"

grep -v '^LDS_AI_MODEL=' "$user_env" >"$user_env.tmp"
mv "$user_env.tmp" "$user_env"

npu_json="$(COMPOSE_PROFILES=ai LDS_AI_RUNTIME=npu "$ROOT/lds" --quiet config show --json --raw 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
python3 -c '
import json,sys
d=json.load(sys.stdin)
services=d["services"]
assert "llm-fastflow" in services
assert "llm-ollama" not in services
s=services["llm-fastflow"]
assert s["image"] == "infocyph/llm-fastflow:latest"
assert s["container_name"] == "LLM_FASTFLOW"
assert not s.get("ports")
assert set(s["networks"]) == {"frontend","backend"}
assert s["environment"]["LLM_FASTFLOW_MODEL"] == "qwen3.5:9b"
assert s["environment"]["FLM_MODEL_PATH"] == "/models"
assert s["environment"]["FLM_SERVE_PORT"] == "11434"
assert s["environment"]["FLM_HOST"] == "0.0.0.0"
assert s["environment"]["FLM_CORS"] == "0"
assert "/dev/accel/accel0" in " ".join(str(x) for x in s.get("devices", []))
assert s["ulimits"]["memlock"]["soft"] == -1
assert s["ulimits"]["memlock"]["hard"] == -1
assert {v["target"] for v in s["volumes"]} == {"/models"}
assert d["volumes"]["lds_llm_fastflow"]["name"] == "LLMFastFlowModels"
tools=services["server-tools"]["environment"]
assert tools["LDS_AI_PROVIDER"] == "llm"
assert tools["LDS_AI_URL"] == "http://llm:11434"
assert tools["LDS_AI_MODEL"] == "qwen3.5:9b"
' <<<"$npu_json"
pass "NPU runtime selects only FastFlow with its provider default model"

amd_json="$(COMPOSE_PROFILES=ai LDS_AI_RUNTIME=amd "$ROOT/lds" --quiet config show --json --raw 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
python3 -c '
import json,sys
d=json.load(sys.stdin)
services=d["services"]
assert "llm-ollama" in services
assert "llm-fastflow" not in services
s=services["llm-ollama"]
assert s["image"] == "infocyph/llm-ollama:amd-latest"
devices=" ".join(str(x) for x in s.get("devices", []))
assert "/dev/kfd" in devices and "/dev/dri" in devices
assert s["environment"]["LLM_OLLAMA_MODEL"] == "qwen3.5:9b"
' <<<"$amd_json"
pass "AMD runtime selects only Ollama with generated ROCm devices"

nvidia_json="$(COMPOSE_PROFILES=ai LDS_AI_RUNTIME=nvidia "$ROOT/lds" --quiet config show --json --raw 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
python3 -c '
import json,sys
d=json.load(sys.stdin)
services=d["services"]
assert "llm-ollama" in services
assert "llm-fastflow" not in services
s=services["llm-ollama"]
assert s["image"] == "infocyph/llm-ollama:latest"
assert s.get("gpus")
assert s["environment"]["LLM_OLLAMA_MODEL"] == "qwen3.5:9b"
' <<<"$nvidia_json"
pass "NVIDIA runtime selects only Ollama with GPU augmentation"

cpu_json="$(COMPOSE_PROFILES=ai LDS_AI_RUNTIME=cpu "$ROOT/lds" --quiet config show --json --raw 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
python3 -c '
import json,sys
d=json.load(sys.stdin)
services=d["services"]
assert "llm-ollama" in services
assert "llm-fastflow" not in services
assert services["llm-ollama"]["environment"]["LLM_OLLAMA_MODEL"] == "qwen3.5:9b"
' <<<"$cpu_json"
pass "CPU runtime selects only Ollama"

if find "$ROOT/docker/compose" -maxdepth 1 -type f -name 'ai-*.yaml' -print -quit | grep -q .; then
  fail "AI-specific Compose files must not exist"
fi
if [[ -d "$ROOT/docker/.runtime" ]] && find "$ROOT/docker/.runtime" -type f -print -quit | grep -q .; then
  fail "temporary AI Compose overrides were not cleaned up"
fi
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'image: infocyph/llm-ollama:latest'
assert_file_contains "$ROOT/lib/compose.sh" 'image: infocyph/llm-ollama:amd-latest'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'image: infocyph/llm-fastflow:latest'
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'aliases: [llm]'
pass "mutually exclusive LLM providers share one common llm network identity"
