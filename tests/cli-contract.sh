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
assert_contains "$help_output" "Execution / Shells"
assert_contains "$help_output" "Generic service/container exec"
assert_contains "$help_output" "Compose-service only"
assert_contains "$help_output" "server-tools only"
pass "lds help"

markdown_output="$("$ROOT/lds" help --markdown)"
assert_contains "$markdown_output" "# LocalDevStack"
assert_contains "$markdown_output" "lds stack up"
assert_contains "$markdown_output" "lds core [domain|service|container]"
assert_contains "$markdown_output" "lds cli <service|container>"
assert_contains "$markdown_output" "argv-preserving execution"
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


assert_file_contains "$ROOT/lds" '_is_public_lds_command()'
if grep -Fq 'declare -F "cmd_$cmd"' "$ROOT/lds"; then
  fail "top-level dispatch still exposes arbitrary cmd_* functions dynamically"
fi
assert_file_contains "$ROOT/lds" 'stack|domain|support|bundle|up|start'
assert_file_contains "$ROOT/lds" 'tools|cli|core|shell|convert|graphify|secrets|rebuild|run)'
pass "top-level LDS command routing is explicit and collision-safe"

if PATH="$tmpbin:$PATH" "$ROOT/lds" graphify --help 2>&1 | grep -Fq 'SERVER_TOOLS is not running'; then
  fail "top-level graphify incorrectly fell through to tool-runner"
fi
pass "top-level Graphify remains a host-side command"

assert_contains "$help_output" "shell [target]"
assert_contains "$markdown_output" "lds shell <target>"
pass "unified shell is exposed in embedded help"

assert_contains "$help_output" "convert docs [--force] <input> <output>"
assert_contains "$markdown_output" "lds convert docs [--force] <input> <output>"
assert_contains "$markdown_output" "lds convert docs --list-input-formats"
assert_contains "$markdown_output" "lds convert image [--force] <input> <output>"
assert_contains "$markdown_output" "lds convert image --formats"
pass "document conversion is exposed in embedded help"

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

# The deterministic document handoff verifies both executor paths:
# reuse SERVER_TOOLS for targets under /app, and exactly one temporary
# container for arbitrary external repositories.
(
  set -euo pipefail
  # shellcheck source=lib/ai.sh
  source "$ROOT/lib/ai.sh"

  hybrid_root="$(mktemp -d)"
  hybrid_log="$hybrid_root/docker.log"
  graphify_hybrid_log="$hybrid_root/graphify.log"
  mounted_root="$hybrid_root/mounted-project"
  mounted_target="$mounted_root/subproject"
  external_target="$hybrid_root/external-project"
  container_tmp_host="$hybrid_root/container-tmp"
  mkdir -p "$mounted_target/graphify-out" "$external_target/graphify-out" "$container_tmp_host"
  printf '%s\n' '{"nodes":[],"edges":[],"hyperedges":[]}' >"$mounted_target/graphify-out/graph.json"
  printf '%s\n' '{"nodes":[],"edges":[],"hyperedges":[]}' >"$external_target/graphify-out/graph.json"

  warn() { printf 'warn:%s\n' "$*" >>"$hybrid_log"; }
  die() { printf 'die:%s\n' "$*" >>"$hybrid_log"; return 1; }
  _realpath() { readlink -f -- "$1"; }
  _project_tools_container_running() { printf '%s' SERVER_TOOLS_TEST; }

  docker_compose() {
    printf 'compose:%s\n' "$*" >>"$hybrid_log"
    case "$*" in
      *"run -d --no-deps "*"server-tools tail -f /dev/null"*)
        printf '%s\n' EPHEMERAL_TOOLS_TEST
        return 0
        ;;
    esac
    return 93
  }

  docker() {
    printf 'docker:%s\n' "$*" >>"$hybrid_log"
    local op="${1:-}"
    shift || true
    case "$op" in
      inspect)
        if [[ "$*" == *'.Destination "/app"'* || "$*" == *'.Destination \"/app\"'* ]]; then
          printf '%s\n' "$mounted_root"
          return 0
        fi
        return 1
        ;;
      cp)
        return 0
        ;;
      rm)
        return 0
        ;;
      exec)
        local -a args=("$@")
        local i=0
        while ((i < ${#args[@]})); do
          case "${args[$i]}" in
            -i) ((i += 1)) ;;
            -e) ((i += 2)) ;;
            *) break ;;
          esac
        done
        local ctr="${args[$i]}"
        ((i += 1))
        local cmd="${args[$i]}"
        ((i += 1))
        local -a rest=("${args[@]:$i}")

        case "$cmd" in
          docstruct)
            if [[ "${rest[*]}" == "graphify-merge --help" ]]; then
              printf '%s\n' 'Usage: docstruct graphify-merge <graph.json> <fragment.json>'
              return 0
            fi
            if [[ "${rest[0]:-}" == graphify && "${rest[1]:-}" != graphify-merge ]]; then
              printf '%s\n' '{"nodes":[],"edges":[],"hyperedges":[],"input_tokens":0,"output_tokens":0}'
              return 0
            fi
            if [[ "${rest[0]:-}" == graphify-merge ]]; then
              if [[ "$ctr" == SERVER_TOOLS_TEST ]]; then
                cat "$mounted_target/graphify-out/graph.json"
              else
                cat "$external_target/graphify-out/graph.json"
              fi
              return 0
            fi
            printf '%s\n' '{"schema":"docker-tools.docstruct/v1","root":"/workspace","files":[],"nodes":[],"edges":[],"unresolved_references":[],"warnings":[],"stats":{"files":0,"nodes":0,"edges":0,"unresolved_references":0}}'
            return 0
            ;;
          aiops)
            printf '%s\n' '{"schema":"docker-tools.docstruct-review/v1","base_schema":"docker-tools.docstruct/v1","base_sha256":"fixture","review_chunks":0,"patch":{"add_nodes":[],"add_edges":[],"corrections":[],"unresolved":[]}}'
            return 0
            ;;
          mktemp)
            printf '%s\n' '/tmp/lds-graphify-docstruct.TEST'
            return 0
            ;;
          rm)
            return 0
            ;;
        esac
        return 94
        ;;
    esac
    return 95
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
elif [[ "${1:-}" == cluster-only ]]; then
  shift
  graph=''
  while (($#)); do
    case "$1" in
      --graph) graph="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$graph" ]] || exit 96
  mkdir -p graphify-out
  cp "$graph" graphify-out/graph.json
fi
SH
  chmod +x "$graphify_hybrid"

  GRAPHIFY_HYBRID_LOG="$graphify_hybrid_log" \
    _graphify_docstruct_available ||
    fail "docstruct capability probe rejected a compatible running Tools container"

  : >"$hybrid_log"
  GRAPHIFY_HYBRID_LOG="$graphify_hybrid_log" \
    _graphify_docstruct_enrich "$graphify_hybrid" "$mounted_target" auto --exclude ignored.md --no-gitignore

  grep -Fq 'documents: reusing existing SERVER_TOOLS container' /dev/null 2>/dev/null || true
  if grep -Fq 'compose:run -d --no-deps' "$hybrid_log"; then
    fail "target under SERVER_TOOLS /app unexpectedly created a temporary Tools container"
  fi
  grep -Fq 'docker:exec -i SERVER_TOOLS_TEST docstruct /app/subproject --compact --exclude ignored.md --no-gitignore' "$hybrid_log" ||
    fail "mounted project was not processed through the existing SERVER_TOOLS container"
  grep -Fq 'docker:exec -i -e DOCSTRUCT_REVIEW_ROOT=/app/subproject SERVER_TOOLS_TEST aiops document-review' "$hybrid_log" ||
    fail "mounted project review did not use the existing SERVER_TOOLS container"
  [[ -r "$mounted_target/graphify-out/graph.json" ]] ||
    fail "existing-container graph publication failed"

  : >"$hybrid_log"
  GRAPHIFY_HYBRID_LOG="$graphify_hybrid_log" \
    _graphify_docstruct_enrich "$graphify_hybrid" "$external_target" auto

  [[ "$(grep -Fc 'compose:run -d --no-deps' "$hybrid_log")" -eq 1 ]] ||
    fail "external project must create exactly one temporary Tools container"
  grep -Fq -- "-v $external_target:/workspace:ro server-tools tail -f /dev/null" "$hybrid_log" ||
    fail "external project was not mounted read-only into the temporary Tools container"
  grep -Fq 'docker:exec -i EPHEMERAL_TOOLS_TEST docstruct /workspace --compact' "$hybrid_log" ||
    fail "external docstruct extraction did not reuse the temporary Tools container"
  grep -Fq 'docker:exec -i -e DOCSTRUCT_REVIEW_ROOT=/workspace EPHEMERAL_TOOLS_TEST aiops document-review' "$hybrid_log" ||
    fail "external semantic review did not reuse the temporary Tools container"
  [[ "$(grep -Fc 'docker:rm -f EPHEMERAL_TOOLS_TEST' "$hybrid_log")" -eq 1 ]] ||
    fail "temporary Tools container was not cleaned up exactly once"
  [[ -r "$external_target/graphify-out/graph.json" ]] ||
    fail "external graph publication failed"
  grep -Fq 'merge-chunks ' "$graphify_hybrid_log" ||
    fail "Graphify public fragment validation was not invoked"
  grep -Fq 'cluster-only --graph ' "$graphify_hybrid_log" ||
    fail "Graphify merged graph round-trip canonicalization was not invoked"
  grep -Fq -- '--no-label --no-viz' "$graphify_hybrid_log" ||
    fail "Graphify merged graph round-trip must stay deterministic and LLM-free"

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
assert_file_contains "$ROOT/lib/ai.sh" '_graphify_tools_app_target'
assert_file_contains "$ROOT/lib/ai.sh" 'documents: reusing existing SERVER_TOOLS container'
assert_file_contains "$ROOT/lib/ai.sh" 'documents: target is outside SERVER_TOOLS /app; starting one temporary Tools container'
assert_file_contains "$ROOT/lib/ai.sh" 'docker_compose run -d --no-deps'
assert_file_contains "$ROOT/lib/ai.sh" 'server-tools tail -f /dev/null'
assert_file_contains "$ROOT/lib/ai.sh" 'docker exec -i "$_GRAPHIFY_TOOLS_CTR"'
assert_file_contains "$ROOT/lib/ai.sh" 'docker rm -f "$ctr"'
assert_file_contains "$ROOT/lib/ai.sh" 'mktemp "$target_abs/graphify-out/.graph.json.docstruct.XXXXXX"'
assert_file_contains "$ROOT/lib/ai.sh" '_graphify_canonicalize_staged_graph'
assert_file_contains "$ROOT/lib/ai.sh" 'cluster-only --graph "$roundtrip_input" --no-label --no-viz'
assert_file_contains "$ROOT/lib/ai.sh" 'documents: canonicalizing merged graph through Graphify before publication'
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
