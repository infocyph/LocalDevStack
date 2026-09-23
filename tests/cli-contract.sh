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
[[ "$(grep -Fc 'args=cluster-only . --backend ollama' "$graphify_log")" -eq 1 ]] ||
  fail "Graphify Ollama bootstrap must cluster the structural graph once"
grep -Fq 'args=label . --backend ollama' "$graphify_log" ||
  fail "Graphify Ollama bootstrap must relabel the enriched graph"
if grep -Fq 'args=cluster-only . --backend ollama --max-concurrency 1' "$graphify_log"; then
  fail "External native Ollama should rely on Graphify's built-in serial labeling guard"
fi

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
[[ "$(grep -Fc 'args=cluster-only . --backend openai --max-concurrency 1' "$graphify_log")" -eq 1 ]] ||
  fail "Graphify FastFlow bootstrap must cluster the structural graph once"
grep -Fq 'args=label . --backend openai --max-concurrency 1' "$graphify_log" ||
  fail "Graphify FastFlow bootstrap must relabel the enriched graph"

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
grep -Fq 'args=cluster-only . --backend openai --max-concurrency 2' "$graphify_log" ||
  fail "Graphify FastFlow explicit concurrency override was not preserved for structural labeling"
grep -Fq 'args=label . --backend openai --max-concurrency 2' "$graphify_log" ||
  fail "Graphify FastFlow explicit concurrency override was not preserved for final relabeling"

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

# The deterministic document handoff is tested independently from the legacy
# fallback above so current published Tools images can remain compatible until
# the new docstruct-capable image is released.
(
  set -euo pipefail
  # shellcheck source=lib/ai.sh
  source "$ROOT/lib/ai.sh"

  hybrid_root="$(mktemp -d)"
  hybrid_log="$hybrid_root/docker.log"
  graphify_hybrid_log="$hybrid_root/graphify.log"
  target="$hybrid_root/project"
  mkdir -p "$target/graphify-out"
  printf '%s\n' '{"nodes":[],"edges":[],"hyperedges":[]}' >"$target/graphify-out/graph.json"

  warn() { printf 'warn:%s\n' "$*" >>"$hybrid_log"; }
  die() { printf 'die:%s\n' "$*" >>"$hybrid_log"; return 1; }

  docker_compose() {
    printf '%s\n' "$*" >>"$hybrid_log"
    case "$*" in
      *"server-tools docstruct graphify-merge --help"*)
        printf '%s\n' 'Usage: docstruct graphify-merge <graph.json> <fragment.json>'
        return 0
        ;;
      *"server-tools docstruct /workspace "*)
        local mount host=''
        for mount in "$@"; do
          case "$mount" in
            *:/docstruct:rw) host="${mount%:/docstruct:rw}" ;;
          esac
        done
        [[ -n "$host" ]] || return 91
        printf '%s\n' '{"schema":"docker-tools.docstruct/v1","root":"/workspace","files":[],"nodes":[],"edges":[],"unresolved_references":[],"warnings":[],"stats":{"files":0,"nodes":0,"edges":0,"unresolved_references":0}}' >"$host/docstruct.json"
        return 0
        ;;
      *"server-tools aiops document-review "*)
        printf '%s\n' '{"schema":"docker-tools.docstruct-review/v1","base_schema":"docker-tools.docstruct/v1","base_sha256":"fixture","review_chunks":0,"patch":{"add_nodes":[],"add_edges":[],"corrections":[],"unresolved":[]}}'
        return 0
        ;;
      *"server-tools docstruct graphify "*)
        local mount host=''
        for mount in "$@"; do
          case "$mount" in
            *:/docstruct:rw) host="${mount%:/docstruct:rw}" ;;
          esac
        done
        [[ -n "$host" ]] || return 92
        printf '%s\n' '{"nodes":[],"edges":[],"hyperedges":[],"input_tokens":0,"output_tokens":0}' >"$host/fragment.json"
        return 0
        ;;
      *"server-tools docstruct graphify-merge "*)
        local mount graph_host=''
        for mount in "$@"; do
          case "$mount" in
            *:/graphify:ro) graph_host="${mount%:/graphify:ro}" ;;
          esac
        done
        [[ -n "$graph_host" ]] || return 94
        cat "$graph_host/graph.json"
        return 0
        ;;
    esac
    return 93
  }

  graphify_hybrid="$hybrid_root/graphify"
  cat >"$graphify_hybrid" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GRAPHIFY_HYBRID_LOG"
if [[ "${1:-}" == merge-chunks ]]; then
  input="$2"
  shift 2
  out=''
  while (($#)); do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  cp "$input" "$out"
fi
SH
  chmod +x "$graphify_hybrid"

  GRAPHIFY_HYBRID_LOG="$graphify_hybrid_log" \
    _graphify_docstruct_available ||
    fail "docstruct capability probe rejected a compatible Tools command"

  GRAPHIFY_HYBRID_LOG="$graphify_hybrid_log" \
    _graphify_docstruct_enrich "$graphify_hybrid" "$target" auto --exclude ignored.md --no-gitignore

  grep -Fq 'server-tools docstruct /workspace --compact --output /docstruct/docstruct.json --exclude ignored.md --no-gitignore' "$hybrid_log" ||
    fail "docstruct scan did not receive Graphify user exclusions"
  grep -Fq 'DOCSTRUCT_REVIEW_ROOT=/workspace' "$hybrid_log" ||
    fail "docstruct review was not confined to the mounted workspace"
  grep -Fq "server-tools docstruct graphify /docstruct/docstruct.json --source-root $target" "$hybrid_log" ||
    fail "Graphify fragment export did not preserve the host provenance root"
  grep -Fq 'server-tools docstruct graphify-merge /graphify/graph.json /docstruct/fragment.json' "$hybrid_log" ||
    fail "docstruct Graphify replacement merge was not invoked"
  if grep -Fq -- '--output /docstruct/merged-graph.json' "$hybrid_log"; then
    fail "docstruct Graphify replacement merge still publishes through the container bind mount"
  fi
  grep -Fq ":/graphify:ro" "$hybrid_log" ||
    fail "Graphify output was not mounted read-only into the Tools merge container"
  grep -Fq ":/docstruct:ro" "$hybrid_log" ||
    fail "docstruct handoff was not mounted read-only for the merge container"
  [[ -r "$target/graphify-out/graph.json" ]] ||
    fail "host-side Graphify output publication failed"
  grep -Fq 'merge-chunks ' "$graphify_hybrid_log" ||
    fail "Graphify public fragment validation was not invoked"

  [[ "$(_graphify_docstruct_mode)" == auto ]] ||
    fail "Graphify docstruct default mode drifted"
  [[ "$(_graphify_doc_review_mode)" == auto ]] ||
    fail "Graphify document review default mode drifted"

  rm -rf "$hybrid_root"
)
pass "Graphify deterministic document handoff"

assert_file_contains "$ROOT/lib/ai.sh" "http://llm.localhost:11434/v1"
assert_file_contains "$ROOT/lib/ai.sh" 'fastflow) printf '\''%s'\'' openai'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_TOKEN_BUDGET:-3000'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_MAX_CONCURRENCY:-1'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_MIN_VERSION:-0.9.65'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_OUTPUT_TOKENS:-8192'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_DOCSTRUCT:-auto'
assert_file_contains "$ROOT/lib/ai.sh" 'LDS_GRAPHIFY_DOC_REVIEW:-auto'
assert_file_contains "$ROOT/lib/ai.sh" "phase 3/3: merging deterministic document structure and relabeling"
assert_file_contains "$ROOT/lib/ai.sh" "server-tools docstruct graphify-merge"
assert_file_contains "$ROOT/lib/ai.sh" '/graphify:ro'
assert_file_contains "$ROOT/lib/ai.sh" '/docstruct:ro'
assert_file_contains "$ROOT/lib/ai.sh" 'server-tools docstruct graphify-merge'
assert_file_contains "$ROOT/lib/ai.sh" '>"$publish_tmp"'
assert_file_contains "$ROOT/lib/ai.sh" 'mktemp "$target_abs/graphify-out/.graph.json.docstruct.XXXXXX"'
assert_file_contains "$ROOT/lib/ai.sh" "--exclude 'requirements*.txt'"
assert_file_contains "$ROOT/lib/ai.sh" "--exclude 'constraints*.txt'"
assert_file_contains "$ROOT/lib/ai.sh" "--exclude 'requirements/*.txt'"
assert_file_contains "$ROOT/lib/ai.sh" "--exclude '**/requirements/*.txt'"
pass "Graphify provider-aware host workflow wrapper"

assert_file_contains "$ROOT/lds" 'exec "$DIR/bin/tool-runner" "$cmd" "$@"'
pass "unknown command fallback remains delegated to tool-runner"

assert_file_contains "$ROOT/lds" 'local -a flags=(-i)'
assert_file_contains "$ROOT/lds" '[[ -t 0 && -t 1 ]] && flags+=(-t)'
pass "proxied host tools preserve piped stdin without forcing a TTY"
