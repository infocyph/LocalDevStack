# shellcheck shell=bash
_tools_exec() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  # NOTE: pass a SINGLE command string; do not pass arrays here.
  docker exec -i "$ctr" sh -lc "$*"
}

_tools_exec_argv() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  local -a flags=(-i)
  [[ -t 0 && -t 1 ]] && flags+=(-t)
  docker exec "${flags[@]}" "$ctr" "$@"
}

cmd_ai() {
  local sub="${1:-status}"
  shift || true
  case "${sub,,}" in
  status | provider) _tools_exec_argv aiops provider "$@" ;;
  ask) _tools_exec_argv askai "$@" ;;
  explain | troubleshoot | review | repo-review | graphify)
    _tools_exec_argv aiops "${sub,,}" "$@"
    ;;
  *) die "ai <status|ask|explain|troubleshoot|review|repo-review|graphify> [args...]" ;;
  esac
}

_graphify_local_base_url() {
  local ctr published host_port
  ctr="$(docker_compose ps -q llm-sm 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$ctr" ]] ||
    die "llm-sm is not running. Enable the ai profile and start the stack first."

  docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -qx true ||
    die "llm-sm container exists but is not running."

  published="$(
    docker inspect -f '{{with (index .NetworkSettings.Ports "11434/tcp")}}{{(index . 0).HostPort}}{{end}}' "$ctr" 2>/dev/null || true
  )"
  [[ "$published" =~ ^[0-9]+$ ]] ||
    die "Graphify needs the llm-sm loopback API. Run: lds llm host-port on && lds up -d llm-sm"

  host_port="$published"
  printf 'http://127.0.0.1:%s/v1' "$host_port"
}

cmd_graphify() {
  need_bin graphify "install the Graphify CLI on the host first"

  local target="${1:-.}"
  [[ $# -eq 0 ]] || shift
  [[ -e "$target" ]] || die "Graphify target does not exist: $target"

  local base_url timeout model api_key graphify_bin arg next_is_model=0 next_is_timeout=0
  base_url="${OLLAMA_BASE_URL:-$(_graphify_local_base_url)}"
  timeout="${GRAPHIFY_API_TIMEOUT:-$(compose_control_value LDS_AI_TIMEOUT 1800)}"
  model="${OLLAMA_MODEL:-$(compose_control_value LDS_AI_MODEL qwen2.5:3b)}"
  api_key="${OLLAMA_API_KEY:-local}"

  # Keep explicit model/timeout overrides consistent across extraction and clustering.
  for arg in "$@"; do
    if ((next_is_model)); then
      model="$arg"
      next_is_model=0
      continue
    fi
    if ((next_is_timeout)); then
      timeout="$arg"
      next_is_timeout=0
      continue
    fi
    case "$arg" in
    --model) next_is_model=1 ;;
    --model=*) model="${arg#--model=}" ;;
    --api-timeout) next_is_timeout=1 ;;
    --api-timeout=*) timeout="${arg#--api-timeout=}" ;;
    --backend | --backend=*)
      die "lds graphify owns --backend=ollama; do not pass --backend"
      ;;
    --no-cluster)
      die "lds graphify already separates extraction and clustering; do not pass --no-cluster"
      ;;
    esac
  done
  ((next_is_model == 0)) || die "--model requires a value"
  ((next_is_timeout == 0)) || die "--api-timeout requires a value"
  [[ -n "$model" ]] || die "Graphify model cannot be empty"
  [[ "$timeout" =~ ^[0-9]+$ ]] && ((timeout >= 1)) ||
    die "GRAPHIFY_API_TIMEOUT/--api-timeout must be a positive integer"

  graphify_bin="$(bin_path graphify)"

  (
    export OLLAMA_BASE_URL="$base_url"
    export OLLAMA_API_KEY="$api_key"
    export OLLAMA_MODEL="$model"
    export GRAPHIFY_API_TIMEOUT="$timeout"

    "$graphify_bin" extract "$target" --backend ollama --no-cluster "$@" &&
      "$graphify_bin" cluster-only "$target" --backend ollama
  )
}

_llm_exec() {
  local ctr
  ctr="$(docker_compose ps -q llm-sm 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$ctr" ]] || die "llm-sm is not running. Enable the ai profile and start the stack first."
  docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -qx true ||
    die "llm-sm container exists but is not running."

  local -a exec_args=(exec)
  [[ -t 0 && -t 1 ]] || exec_args+=(-T)
  docker_compose "${exec_args[@]}" llm-sm llm-sm "$@"
}

cmd_llm() {
  local sub="${1:-models}"
  shift || true

  case "${sub,,}" in
  runtime)
    local mode="${1:-}"
    if [[ -z "$mode" ]]; then
      printf '%s\n' "$(compose_control_value LDS_AI_RUNTIME "$(detect_ai_runtime)")"
      return 0
    fi
    case "${mode,,}" in
    cpu | nvidia | amd)
      local normalized arch
      normalized="${mode,,}"
      arch="$(llm_arch_for_runtime "$normalized")"
      update_env "$ENV_DOCKER" LDS_AI_RUNTIME "$normalized"
      update_env "$ENV_DOCKER" LDS_LLM_ARCH "$arch"
      ok "LLM runtime set to $normalized (infocyph/llm-sm:$arch). Recreate llm-sm to apply the change."
      ;;
    *) die "llm runtime <cpu|nvidia|amd>" ;;
    esac
    ;;
  host-port)
    local state="${1:-status}"
    case "${state,,}" in
    status) printf '%s\n' "$(compose_control_value LDS_LLM_HOST_PORT 0)" ;;
    on | enable | enabled | 1)
      update_env "$ENV_DOCKER" LDS_LLM_HOST_PORT 1
      ok "Direct LLM API enabled on loopback only. Recreate llm-sm to apply."
      ;;
    off | disable | disabled | 0)
      update_env "$ENV_DOCKER" LDS_LLM_HOST_PORT 0
      ok "Direct LLM host API disabled. Recreate llm-sm to apply."
      ;;
    *) die "llm host-port <status|on|off>" ;;
    esac
    ;;
  models | ps | show | pull | rm | unload | run | ask | chat | prompt | code | review | json | ai-commit | ollama | api | version)
    _llm_exec "${sub,,}" "$@"
    ;;
  help | -h | --help)
    printf '%s\n' "llm <models|ps|show|pull|rm|unload|run|ask|chat|prompt|code|review|json|ai-commit|ollama|api|version>"
    printf '%s\n' "llm runtime <cpu|nvidia|amd>"
    printf '%s\n' "llm host-port <status|on|off>"
    ;;
  *) die "llm <models|ps|show|pull|rm|unload|run|ask|chat|prompt|code|review|json|ai-commit|ollama|api|version|runtime|host-port>" ;;
  esac
}

