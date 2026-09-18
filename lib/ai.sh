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
      printf '%s\n' "$(compose_control_value LDS_AI_RUNTIME cpu)"
      return 0
    fi
    case "${mode,,}" in
    cpu | nvidia | amd)
      update_env "$ENV_DOCKER" LDS_AI_RUNTIME "${mode,,}"
      ok "LLM runtime set to ${mode,,}. Recreate llm-sm to apply the change."
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

