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

_active_llm_runtime() {
  effective_ai_runtime
}

_active_llm_service() {
  ai_service_for_runtime "$(_active_llm_runtime)"
}

_active_llm_provider() {
  ai_provider_for_runtime "$(_active_llm_runtime)"
}

_active_llm_cli() {
  case "$(_active_llm_provider)" in
  fastflow) printf '%s' llm-fastflow ;;
  ollama) printf '%s' llm-ollama ;;
  *) return 1 ;;
  esac
}

_graphify_local_base_url() {
  local service provider_ctr nginx_ctr
  service="$(_active_llm_service)"

  provider_ctr="$(docker_compose ps -q "$service" 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$provider_ctr" ]] ||
    die "$service is not running. Enable the ai profile and start the stack first."
  docker inspect -f '{{.State.Running}}' "$provider_ctr" 2>/dev/null | grep -qx true ||
    die "$service container exists but is not running."

  nginx_ctr="$(docker_compose ps -q nginx 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$nginx_ctr" ]] ||
    die "nginx is not running. Start the LocalDevStack edge before using Graphify."
  docker inspect -f '{{.State.Running}}' "$nginx_ctr" 2>/dev/null | grep -qx true ||
    die "nginx container exists but is not running."

  printf '%s' 'http://llm.localhost:11434/v1'
}

_graphify_local_model_preflight() {
  local model="${1:-}" response
  [[ -n "$model" ]] || return 1
  need_bin curl "install curl to validate the selected LocalDevStack model"

  response="$(curl --connect-timeout 3 --max-time 10 -fsS     'http://llm.localhost:11434/v1/models' 2>/dev/null)" ||
    die "The selected LocalDevStack LLM endpoint is unavailable. Start the ai profile first."

  printf '%s' "$response" | grep -Fq ""$model"" ||
    die "Model '$model' is not available from the active LocalDevStack provider. Run: lds llm pull $model"
}

cmd_graphify() {
  need_bin graphify "install the Graphify CLI on the host first"

  local target="${1:-.}"
  [[ $# -eq 0 ]] || shift
  [[ -e "$target" ]] || die "Graphify target does not exist: $target"

  local base_url timeout model api_key graphify_bin arg next_is_model=0 next_is_timeout=0 local_provider=0
  if [[ -n "${OLLAMA_BASE_URL:-}" ]]; then
    base_url="$OLLAMA_BASE_URL"
  else
    base_url="$(_graphify_local_base_url)"
    local_provider=1
  fi
  timeout="${GRAPHIFY_API_TIMEOUT:-$(compose_control_value LDS_AI_TIMEOUT 1800)}"
  model="${OLLAMA_MODEL:-$(effective_ai_model "$(_active_llm_runtime)")}"
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

  ((local_provider == 0)) || _graphify_local_model_preflight "$model"

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
  local service cli ctr
  service="$(_active_llm_service)"
  cli="$(_active_llm_cli)"

  ctr="$(docker_compose ps -q "$service" 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$ctr" ]] || die "$service is not running. Enable the ai profile and start the stack first."
  docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -qx true ||
    die "$service container exists but is not running."

  local -a exec_args=(exec)
  [[ -t 0 && -t 1 ]] || exec_args+=(-T)
  docker_compose "${exec_args[@]}" "$service" "$cli" "$@"
}

_llm_require_provider() {
  local expected="$1" command="$2" active
  active="$(_active_llm_provider)"
  [[ "$active" == "$expected" ]] ||
    die "llm $command is available only with the $expected provider; active provider is $active."
}

cmd_llm() {
  local sub="${1:-models}"
  shift || true

  case "${sub,,}" in
  runtime)
    local mode="${1:-}"
    if [[ -z "$mode" ]]; then
      printf '%s\n' "$(_active_llm_runtime)"
      return 0
    fi

    case "${mode,,}" in
    auto)
      update_env "$ENV_DOCKER" LDS_AI_RUNTIME ""
      update_env "$ENV_DOCKER" LDS_LLM_ARCH ""
      update_env "$ENV_DOCKER" LDS_AI_IGPU_ENABLE ""
      local detected
      detected="$(detect_ai_runtime)"
      ok "LLM runtime set to auto; detected $detected ($(ai_provider_for_runtime "$detected")). Recreate the AI service to apply it."
      ;;
    cpu | nvidia | amd | npu)
      local normalized arch igpu_enable provider image
      normalized="${mode,,}"
      arch="$(llm_arch_for_runtime "$normalized")"
      igpu_enable="$(ai_igpu_default_for_runtime "$normalized")"
      provider="$(ai_provider_for_runtime "$normalized")"

      if [[ "$normalized" == "npu" ]] && ! fastflow_npu_supported; then
        warn "No FastFlow-supported XDNA2 NPU is currently detected; the explicit npu runtime will still be persisted."
      fi

      update_env "$ENV_DOCKER" LDS_AI_RUNTIME "$normalized"
      update_env "$ENV_DOCKER" LDS_LLM_ARCH "$arch"
      update_env "$ENV_DOCKER" LDS_AI_IGPU_ENABLE "$igpu_enable"

      if [[ "$provider" == "fastflow" ]]; then
        image="infocyph/llm-fastflow:latest"
      else
        image="infocyph/llm-ollama:$arch"
      fi
      ok "LLM runtime set to $normalized ($provider, $image). Recreate the AI service to apply the change."
      ;;
    *) die "llm runtime <auto|cpu|nvidia|amd|npu>" ;;
    esac
    ;;

  models | list | pull | rm | remove | run | ask | chat | prompt | code | review | json | ai-commit | api | version)
    _llm_exec "${sub,,}" "$@"
    ;;

  ps | show | unload | ollama)
    _llm_require_provider ollama "${sub,,}"
    _llm_exec "${sub,,}" "$@"
    ;;

  validate | check | flm)
    _llm_require_provider fastflow "${sub,,}"
    _llm_exec "${sub,,}" "$@"
    ;;

  provider)
    printf '%s\n' "$(_active_llm_provider)"
    ;;

  help | -h | --help)
    printf '%s\n' "llm <models|pull|rm|run|ask|chat|prompt|code|review|json|ai-commit|api|version>"
    printf '%s\n' "llm provider"
    printf '%s\n' "llm runtime <auto|cpu|nvidia|amd|npu>"
    printf '%s\n' "Ollama-only: llm <ps|show|unload|ollama>"
    printf '%s\n' "FastFlow-only: llm <validate|check|flm>"
    ;;

  *) die "llm <models|pull|rm|run|ask|chat|prompt|code|review|json|ai-commit|api|version|provider|runtime>" ;;
  esac
}
