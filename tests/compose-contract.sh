#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is required"

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
render apache --profile apache
render ai --profile ai
docker compose --project-directory "$ROOT" \
  -f "$ROOT/docker/compose/main.yaml" \
  -f "$ROOT/docker/compose/ai-nvidia.yaml" \
  --env-file "$release_env" --env-file "$user_env" --profile ai config --quiet
docker compose --project-directory "$ROOT" \
  -f "$ROOT/docker/compose/main.yaml" \
  -f "$ROOT/docker/compose/ai-amd.yaml" \
  --env-file "$release_env" --env-file "$user_env" --profile ai config --quiet
docker compose --project-directory "$ROOT" \
  -f "$ROOT/docker/compose/main.yaml" \
  -f "$ROOT/docker/compose/ai-host-port.yaml" \
  --env-file "$release_env" --env-file "$user_env" --profile ai config --quiet

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

printf '%s\n' 'LDS_TOOLS_IMAGE=example.invalid/tools:user-override' >>"$user_env"
user_override="$("${compose[@]}" config)"
assert_contains "$user_override" "image: example.invalid/tools:user-override"
pass "docker/.env overrides release defaults"

shell_override="$(
  LDS_TOOLS_IMAGE=example.invalid/tools:shell-override "${compose[@]}" config
)"
assert_contains "$shell_override" "image: example.invalid/tools:shell-override"
pass "shell override wins over user and release env files"

core_json="$("${compose[@]}" config --format json)"
python3 -c '
import json,sys
d=json.load(sys.stdin)
assert "apache" not in d.get("services", {})
assert "llm-sm" not in d.get("services", {})
assert d["volumes"]["lds_tools_state"]["name"] == "ToolsState"
tools=d["services"]["server-tools"]
targets={v["target"] for v in tools["volumes"]}
assert "/etc/share/state" in targets
' <<<"$core_json"
pass "optional Apache/AI stay outside default stack and Tools state is persistent"

apache_json="$("${compose[@]}" --profile apache config --format json)"
python3 -c '
import json,sys
d=json.load(sys.stdin)
s=d["services"]["apache"]
assert s["image"] == "infocyph/apache:latest"
assert s["profiles"] == ["apache"]
assert "nginx" in s["depends_on"]
' <<<"$apache_json"
pass "Apache backend is activated only through its profile"

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
tools=d["services"]["server-tools"]["environment"]
assert tools["LDS_AI_ENABLED"] == "auto"
assert tools["LDS_AI_PROVIDER"] == "ollama"
assert tools["LDS_AI_URL"] == "http://llm-sm:11434"
assert tools["LDS_AI_MODEL"] == "qwen2.5:3b"
' <<<"$ai_json"
pass "base AI profile is internal-only and deterministic"

amd_json="$(docker compose --project-directory "$ROOT" -f "$ROOT/docker/compose/main.yaml" -f "$ROOT/docker/compose/ai-amd.yaml" --env-file "$release_env" --env-file "$user_env" --profile ai config --format json)"
python3 -c '
import json,sys
s=json.load(sys.stdin)["services"]["llm-sm"]
assert s["image"] == "infocyph/llm-sm:amd-latest"
devices=" ".join(str(x) for x in s.get("devices", []))
assert "/dev/kfd" in devices and "/dev/dri" in devices
' <<<"$amd_json"
pass "AMD AI override"

nvidia_yaml="$(docker compose --project-directory "$ROOT" -f "$ROOT/docker/compose/main.yaml" -f "$ROOT/docker/compose/ai-nvidia.yaml" --env-file "$release_env" --env-file "$user_env" --profile ai config)"
assert_contains "$nvidia_yaml" "gpus:"
pass "NVIDIA AI override"

host_json="$(docker compose --project-directory "$ROOT" -f "$ROOT/docker/compose/main.yaml" -f "$ROOT/docker/compose/ai-host-port.yaml" --env-file "$release_env" --env-file "$user_env" --profile ai config --format json)"
python3 -c '
import json,sys
ports=json.load(sys.stdin)["services"]["llm-sm"]["ports"]
assert len(ports) == 1
p=ports[0]
assert p["host_ip"] == "127.0.0.1"
assert int(p["target"]) == 11434 and int(p["published"]) == 11434
' <<<"$host_json"
pass "direct Ollama port is explicit loopback-only"
