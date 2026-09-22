#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

help_output="$("$ROOT/lds" help)"
assert_contains "$help_output" "LocalDevStack"
assert_contains "$help_output" "Stack"
assert_contains "$help_output" "Domain"
assert_contains "$help_output" "Setup"
pass "lds help"

markdown_output="$("$ROOT/lds" help --markdown)"
assert_contains "$markdown_output" "# LocalDevStack"
assert_contains "$markdown_output" "lds stack up"
pass "lds markdown help"

global_help="$("$ROOT/lds" --help)"
assert_contains "$global_help" "LocalDevStack"
pass "lds --help"

code=0
"$ROOT/lds" >/tmp/lds-noargs.out 2>/tmp/lds-noargs.err || code=$?
[[ "$code" -eq 1 ]] || fail "no-argument invocation must exit 1; got $code"
grep -q "LocalDevStack" /tmp/lds-noargs.out || fail "no-argument invocation must print help"
pass "no-argument behavior"

tmpbin="$(mktemp -d)"
trap 'rm -rf "$tmpbin" /tmp/lds-noargs.out /tmp/lds-noargs.err' EXIT
cat >"$tmpbin/docker" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$tmpbin/docker"

stack_help="$(PATH="$tmpbin:$PATH" "$ROOT/lds" stack help)"
assert_contains "$stack_help" "LocalDevStack"
pass "grouped stack help routing"
assert_contains "$help_output" "graphify [path]"
assert_contains "$markdown_output" "lds graphify"
pass "Graphify workflow help"

graphify_log="$(mktemp)"
cat >"$tmpbin/graphify" <<'SH'
#!/usr/bin/env sh
if [ "${1-}" = "--version" ]; then
  printf '%s\n' 'graphify 0.9.65'
  exit 0
fi
printf 'ollama_base=%s ollama_model=%s openai_base=%s openai_model=%s timeout=%s args=%s\n' \
  "${OLLAMA_BASE_URL-}" "${OLLAMA_MODEL-}" "${OPENAI_BASE_URL-}" "${OPENAI_MODEL-}" \
  "${GRAPHIFY_API_TIMEOUT-}" "$*" >>"$GRAPHIFY_TEST_LOG"
SH
chmod +x "$tmpbin/graphify"

# Ollama runtime keeps Graphify's native Ollama backend.
PATH="$tmpbin:$PATH" \
LDS_AI_RUNTIME=cpu \
OLLAMA_BASE_URL=http://custom-ollama.test:11434/v1 \
OLLAMA_MODEL=test-ollama \
LDS_AI_TIMEOUT=1800 \
GRAPHIFY_TEST_LOG="$graphify_log" \
  "$ROOT/lds" graphify . --api-timeout 42 --mode deep >/dev/null

grep -Fq 'ollama_base=http://custom-ollama.test:11434/v1 ollama_model=test-ollama openai_base= openai_model= timeout=42 args=extract . --backend ollama --no-cluster --code-only --api-timeout 42 --mode deep' "$graphify_log" ||
  fail "Graphify Ollama code-first bootstrap contract failed"
grep -Fq 'ollama_base=http://custom-ollama.test:11434/v1 ollama_model=test-ollama openai_base= openai_model= timeout=42 args=extract . --backend ollama --no-cluster --api-timeout 42 --mode deep' "$graphify_log" ||
  fail "Graphify Ollama semantic enrichment contract failed"
[[ "$(grep -Fc 'args=cluster-only . --backend ollama --max-concurrency 1' "$graphify_log")" -eq 2 ]] ||
  fail "Graphify Ollama bootstrap must cluster structural and enriched graphs"

# FastFlow runtime uses Graphify's generic OpenAI backend and conservative local
# chunking defaults so qwen3.5:9b does not receive oversized semantic requests.
: >"$graphify_log"
PATH="$tmpbin:$PATH" \
LDS_AI_RUNTIME=npu \
OPENAI_BASE_URL=http://custom-fastflow.test:11434/v1 \
OPENAI_MODEL=test-fastflow \
LDS_AI_TIMEOUT=1800 \
GRAPHIFY_TEST_LOG="$graphify_log" \
  "$ROOT/lds" graphify . --mode deep >/dev/null

grep -Fq 'ollama_base= ollama_model= openai_base=http://custom-fastflow.test:11434/v1 openai_model=test-fastflow timeout=1800 args=extract . --backend openai --no-cluster --code-only --token-budget 3000 --max-concurrency 1 --mode deep' "$graphify_log" ||
  fail "Graphify FastFlow code-first bootstrap contract failed"
grep -Fq 'ollama_base= ollama_model= openai_base=http://custom-fastflow.test:11434/v1 openai_model=test-fastflow timeout=1800 args=extract . --backend openai --no-cluster --token-budget 3000 --max-concurrency 1 --mode deep' "$graphify_log" ||
  fail "Graphify FastFlow semantic enrichment contract failed"
[[ "$(grep -Fc 'args=cluster-only . --backend openai --max-concurrency 1' "$graphify_log")" -eq 2 ]] ||
  fail "Graphify FastFlow bootstrap must cluster structural and enriched graphs"

# Explicit Graphify resource controls always win over LocalDevStack defaults.
: >"$graphify_log"
PATH="$tmpbin:$PATH" \
LDS_AI_RUNTIME=npu \
OPENAI_BASE_URL=http://custom-fastflow.test:11434/v1 \
OPENAI_MODEL=test-fastflow \
GRAPHIFY_TEST_LOG="$graphify_log" \
  "$ROOT/lds" graphify . --token-budget 6000 --max-concurrency 2 >/dev/null

grep -Fq 'args=extract . --backend openai --no-cluster --code-only --token-budget 6000 --max-concurrency 2' "$graphify_log" ||
  fail "Graphify FastFlow explicit resource overrides were not preserved in bootstrap"
grep -Fq 'args=extract . --backend openai --no-cluster --token-budget 6000 --max-concurrency 2' "$graphify_log" ||
  fail "Graphify FastFlow explicit resource overrides were not preserved in semantic enrichment"

# Explicit --code-only remains a single structural build; it does not opt into
# automatic semantic enrichment.
: >"$graphify_log"
PATH="$tmpbin:$PATH" \
LDS_AI_RUNTIME=npu \
OPENAI_BASE_URL=http://custom-fastflow.test:11434/v1 \
OPENAI_MODEL=test-fastflow \
GRAPHIFY_TEST_LOG="$graphify_log" \
  "$ROOT/lds" graphify . --code-only >/dev/null

[[ "$(grep -Fc 'args=extract . --backend openai --no-cluster' "$graphify_log")" -eq 1 ]] ||
  fail "Explicit Graphify --code-only must remain single-phase"
grep -Fq 'args=extract . --backend openai --no-cluster --token-budget 3000 --max-concurrency 1 --code-only' "$graphify_log" ||
  fail "Explicit Graphify --code-only flag was not preserved"
[[ "$(grep -Fc 'args=cluster-only . --backend openai --max-concurrency 1' "$graphify_log")" -eq 1 ]] ||
  fail "Explicit Graphify --code-only must cluster exactly once"

rm -f "$graphify_log"
assert_file_contains "$ROOT/lib/ai.sh" "http://llm.localhost:11434/v1"
assert_file_contains "$ROOT/lib/ai.sh" 'fastflow) printf '\''%s'\'' openai'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_TOKEN_BUDGET:-3000'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_MAX_CONCURRENCY:-1'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_MIN_VERSION:-0.9.65'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_OUTPUT_TOKENS:-8192'
pass "Graphify provider-aware host workflow wrapper"

assert_file_contains "$ROOT/lds" 'exec "$DIR/bin/tool-runner" "$cmd" "$@"'
pass "unknown command fallback remains delegated to tool-runner"

assert_file_contains "$ROOT/lds" 'local -a flags=(-i)'
assert_file_contains "$ROOT/lds" '[[ -t 0 && -t 1 ]] && flags+=(-t)'
pass "proxied host tools preserve piped stdin without forcing a TTY"
