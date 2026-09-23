#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

python3 "$ROOT/tests/fixtures/fake-ollama/server.py" &
server_pid=$!

for _ in {1..50}; do
  if curl -fsS http://127.0.0.1:11434/v1/models >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS http://127.0.0.1:11434/v1/models >/dev/null

mkdir -p "$tmp/provider/.graphify" "$tmp/target"
cat >"$tmp/target/README.md" <<'MD'
# Direct Graphify Provider

This document describes the direct LocalDevStack Graphify provider path.
MD

cat >"$tmp/provider/.graphify/providers.json" <<'JSON'
{
  "lds-ci": {
    "base_url": "http://127.0.0.1:11434/v1",
    "default_model": "qwen3.5:9b",
    "env_key": "LDS_GRAPHIFY_API_KEY",
    "max_tokens": 8192
  }
}
JSON

(
  cd "$tmp/provider"
  LDS_GRAPHIFY_API_KEY=local \
  GRAPHIFY_ALLOW_LOCAL_PROVIDERS=1 \
  GRAPHIFY_MAX_RETRIES=0 \
  GRAPHIFY_MAX_RETRY_DEPTH=0 \
    graphify extract "$tmp/target" \
      --backend lds-ci \
      --no-cluster \
      --token-budget 1000 \
      --max-concurrency 1
)

jq -e '
  any(.nodes[]?;
    .id == "readme_document"
    and .file_type == "document"
    and .source_file == "README.md"
  )
' "$tmp/target/graphify-out/graph.json" >/dev/null
