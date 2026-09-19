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
LDS_LLM_ARCH=latest
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
assert d["services"]["elasticsearch"]["image"] == "elasticsearch:9.5.3"
assert d["services"]["kibana"]["image"] == "kibana:9.5.3"
assert d["services"]["filebeat"]["image"] == "docker.elastic.co/beats/filebeat:9.5.3"
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
assert "llm-sm" not in d.get("services", {})
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
s=d["services"]["llm-sm"]
assert s["image"] == "infocyph/llm-sm:latest"
assert "container_name" not in s
assert not s.get("ports")
assert set(s["networks"]) == {"frontend","backend"}
targets={v["target"] for v in s["volumes"]}
assert targets == {"/root/.ollama"}
assert d["volumes"]["lds_llm"]["name"] == "LLMModels"
env=s["environment"]
assert env["LLM_SM_MODEL"] == "qwen2.5:3b"
assert env["LLM_SM_SYSTEM"] == ""
assert env["LLM_SM_INPUT_WARN_BYTES"] == "1048576"
assert env["LLM_SM_INPUT_MAX_BYTES"] == "0"
assert env["LLM_SM_ATTACHMENT_MAX_BYTES"] == "16777216"
assert env["LLM_SM_ATTACHMENTS_MAX_BYTES"] == "33554432"
assert env["LLM_SM_ATTACHMENT_MAX_COUNT"] == "16"
assert env["LLM_SM_PDF_MAX_PAGES"] == "24"
assert env["LLM_SM_PDF_DPI"] == "120"
assert env["LLM_SM_ALLOW_LARGE_INPUT"] == "0"
assert env["OLLAMA_NUM_PARALLEL"] == "1"
assert env["OLLAMA_MAX_LOADED_MODELS"] == "1"
assert env["OLLAMA_KEEP_ALIVE"] == "5m"
assert env["OLLAMA_NO_CLOUD"] == "1"
tools=d["services"]["server-tools"]["environment"]
assert tools["LDS_AI_ENABLED"] == "auto"
assert tools["LDS_AI_PROVIDER"] == "ollama"
assert tools["LDS_AI_URL"] == "http://llm-sm:11434"
assert tools["LDS_AI_MODEL"] == "qwen2.5:3b"
' <<<"$ai_json"
pass "companion-owned AI profile is internal-only and deterministic"

printf '%s\n' 'LDS_AI_MODEL=qwen2.5:1.5b' 'LLM_SM_PDF_MAX_PAGES=12' 'LLM_SM_SYSTEM=Answer briefly.' >>"$user_env"
ai_override_json="$("${compose[@]}" --profile ai config --format json)"
python3 -c '
import json,sys
s=json.load(sys.stdin)["services"]["llm-sm"]
env=s["environment"]
assert env["LLM_SM_MODEL"] == "qwen2.5:1.5b"
assert env["LLM_SM_PDF_MAX_PAGES"] == "12"
assert env["LLM_SM_SYSTEM"] == "Answer briefly."
' <<<"$ai_override_json"
pass "LocalDevStack forwards configured model and provider options into llm-sm"

amd_json="$(COMPOSE_PROFILES=ai LDS_AI_RUNTIME=amd "$ROOT/lds" --quiet config show --json --raw 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
python3 -c '
import json,sys
s=json.load(sys.stdin)["services"]["llm-sm"]
assert s["image"] == "infocyph/llm-sm:amd-latest"
devices=" ".join(str(x) for x in s.get("devices", []))
assert "/dev/kfd" in devices and "/dev/dri" in devices
' <<<"$amd_json"
pass "AMD AI runtime is generated dynamically"

nvidia_json="$(COMPOSE_PROFILES=ai LDS_AI_RUNTIME=nvidia "$ROOT/lds" --quiet config show --json --raw 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
python3 -c '
import json,sys
s=json.load(sys.stdin)["services"]["llm-sm"]
assert s["image"] == "infocyph/llm-sm:latest"
assert s.get("gpus")
' <<<"$nvidia_json"
pass "NVIDIA AI runtime is generated dynamically"

host_json="$(COMPOSE_PROFILES=ai LDS_AI_RUNTIME=cpu LDS_LLM_HOST_PORT=1 "$ROOT/lds" --quiet config show --json --raw 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
python3 -c '
import json,sys
ports=json.load(sys.stdin)["services"]["llm-sm"]["ports"]
assert len(ports) == 1
p=ports[0]
assert p["host_ip"] == "127.0.0.1"
assert int(p["target"]) == 11434 and int(p["published"]) == 11434
' <<<"$host_json"
pass "direct Ollama port is generated dynamically and loopback-only"

if find "$ROOT/docker/compose" -maxdepth 1 -type f -name 'ai-*.yaml' -print -quit | grep -q .; then
  fail "AI-specific Compose files must not exist"
fi
if [[ -d "$ROOT/docker/.runtime" ]] && find "$ROOT/docker/.runtime" -type f -print -quit | grep -q .; then
  fail "temporary AI Compose overrides were not cleaned up"
fi
assert_file_contains "$ROOT/docker/compose/companion.yaml" 'image: infocyph/llm-sm:${LDS_LLM_ARCH}'
pass "single LLM service plus ephemeral hardware/port overrides"
