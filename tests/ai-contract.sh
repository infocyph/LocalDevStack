#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

image="lds-fake-ollama:ci"
container="lds-fake-ollama-ci"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build -q -t "$image" "$ROOT/tests/fixtures/fake-ollama" >/dev/null
docker run -d --name "$container" "$image" >/dev/null

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
