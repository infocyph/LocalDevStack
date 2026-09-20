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
  need_bin jq "install jq to validate the selected LocalDevStack model"

  response="$(curl --connect-timeout 3 --max-time 10 -fsS \
    'http://llm.localhost:11434/v1/models' 2>/dev/null)" ||
    die "The selected LocalDevStack LLM endpoint is unavailable. Start the ai profile first."

  jq -e --arg model "$model" '[.data[]?.id // empty] | index($model) != null' <<<"$response" >/dev/null 2>&1 ||
    die "Model '$model' is not available from the active LocalDevStack provider. Run: lds llm pull $model"
}

_graphify_backend_for_provider() {
  case "${1,,}" in
  fastflow) printf '%s' openai ;;
  ollama) printf '%s' ollama ;;
  *) return 1 ;;
  esac
}

_graphify_local_backend_for_provider() {
  case "${1,,}" in
  fastflow) printf '%s' lds-fastflow ;;
  ollama) printf '%s' lds-ollama ;;
  *) return 1 ;;
  esac
}

_graphify_write_local_provider() {
  local dir="$1" provider="$2" base_url="$3" model="$4" token_budget="$5" think_mode="${6:-off}"
  local backend num_ctx
  backend="$(_graphify_local_backend_for_provider "$provider")" || return 1

  mkdir -p "$dir/.graphify"
  case "$provider" in
  fastflow)
    case "$think_mode" in
    off)
      jq -n \
        --arg backend "$backend" \
        --arg base_url "$base_url" \
        --arg model "$model" \
        '{
          ($backend): {
            base_url: $base_url,
            default_model: $model,
            env_key: "LDS_GRAPHIFY_API_KEY",
            extra_body: {think: false}
          }
        }' >"$dir/.graphify/providers.json"
      ;;
    on)
      jq -n \
        --arg backend "$backend" \
        --arg base_url "$base_url" \
        --arg model "$model" \
        '{
          ($backend): {
            base_url: $base_url,
            default_model: $model,
            env_key: "LDS_GRAPHIFY_API_KEY",
            reasoning_effort: "high",
            extra_body: {think: true}
          }
        }' >"$dir/.graphify/providers.json"
      ;;
    auto)
      jq -n \
        --arg backend "$backend" \
        --arg base_url "$base_url" \
        --arg model "$model" \
        '{
          ($backend): {
            base_url: $base_url,
            default_model: $model,
            env_key: "LDS_GRAPHIFY_API_KEY"
          }
        }' >"$dir/.graphify/providers.json"
      ;;
    *) return 1 ;;
    esac
    ;;
  ollama)
    num_ctx=$((token_budget + 8192 + 2400))
    ((num_ctx < 8192)) && num_ctx=8192
    ((num_ctx > 131072)) && num_ctx=131072
    num_ctx=$((((num_ctx + 1023) / 1024) * 1024))
    jq -n \
      --arg backend "$backend" \
      --arg base_url "$base_url" \
      --arg model "$model" \
      --argjson num_ctx "$num_ctx" \
      '{
        ($backend): {
          base_url: $base_url,
          default_model: $model,
          env_key: "LDS_GRAPHIFY_API_KEY",
          reasoning_effort: "none",
          extra_body: {
            options: {num_ctx: $num_ctx},
            keep_alive: "30m"
          }
        }
      }' >"$dir/.graphify/providers.json"
    ;;
  *) return 1 ;;
  esac

  printf '%s' "$backend"
}

_graphify_python_bin() {
  local graphify_bin="${1:-}" first_line="" candidate=""

  for candidate in python3 python; do
    if type -P -- "$candidate" >/dev/null 2>&1; then
      type -P -- "$candidate"
      return 0
    fi
  done

  if [[ -n "$graphify_bin" && -f "$graphify_bin" ]]; then
    IFS= read -r first_line <"$graphify_bin" || true
    if [[ "$first_line" == '#!'* ]]; then
      candidate="${first_line#\#!}"
      candidate="${candidate%% *}"
      if [[ -x "$candidate" && "${candidate##*/}" == python* ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    fi
  fi
  return 1
}

_graphify_diagnostics_enabled() {
  case "${LDS_GRAPHIFY_DIAGNOSTICS:-0}" in
  1 | true | TRUE | yes | YES | on | ON) return 0 ;;
  0 | false | FALSE | no | NO | off | OFF) return 1 ;;
  *) die "LDS_GRAPHIFY_DIAGNOSTICS must be true/false" ;;
  esac
}

cmd_graphify() {
  need_bin graphify "install the Graphify CLI on the host first"

  local target="${1:-.}"
  [[ $# -eq 0 ]] || shift
  [[ -e "$target" ]] || die "Graphify target does not exist: $target"

  local runtime provider backend base_url timeout model api_key graphify_bin arg provider_dir target_abs
  local graphify_python="" diagnostic_root="" diagnostic_log="" diagnostic_preview="4096" graphify_think="off"
  local diagnostic_mode="off"
  local local_provider=0
  local next_is_model=0 next_is_timeout=0 next_is_token_budget=0 next_is_max_concurrency=0
  local has_token_budget=0 has_max_concurrency=0
  local token_budget_value="" max_concurrency_value=""
  local -a graphify_defaults=()

  runtime="$(_active_llm_runtime)"
  provider="$(_active_llm_provider)"
  backend="$(_graphify_backend_for_provider "$provider")" ||
    die "Unsupported active LLM provider for Graphify: $provider"

  case "$backend" in
  openai)
    if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
      base_url="$OPENAI_BASE_URL"
    else
      base_url="$(_graphify_local_base_url)"
      local_provider=1
    fi
    model="${OPENAI_MODEL:-$(effective_ai_model "$runtime")}"
    api_key="${OPENAI_API_KEY:-local}"
    ;;
  ollama)
    if [[ -n "${OLLAMA_BASE_URL:-}" ]]; then
      base_url="$OLLAMA_BASE_URL"
    else
      base_url="$(_graphify_local_base_url)"
      local_provider=1
    fi
    model="${OLLAMA_MODEL:-$(effective_ai_model "$runtime")}"
    api_key="${OLLAMA_API_KEY:-local}"
    ;;
  esac

  timeout="${GRAPHIFY_API_TIMEOUT:-$(compose_control_value LDS_AI_TIMEOUT 1800)}"

  case "${LDS_GRAPHIFY_THINK:-off}" in
  off | false | 0) graphify_think=off ;;
  on | true | 1) graphify_think=on ;;
  auto | default) graphify_think=auto ;;
  *) die "LDS_GRAPHIFY_THINK must be off/on/auto" ;;
  esac

  # Keep explicit model/timeout/resource overrides consistent while LocalDevStack
  # retains ownership of backend selection and the two-stage extract/cluster flow.
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
    if ((next_is_token_budget)); then
      token_budget_value="$arg"
      next_is_token_budget=0
      continue
    fi
    if ((next_is_max_concurrency)); then
      max_concurrency_value="$arg"
      next_is_max_concurrency=0
      continue
    fi

    case "$arg" in
    --model) next_is_model=1 ;;
    --model=*) model="${arg#--model=}" ;;
    --api-timeout) next_is_timeout=1 ;;
    --api-timeout=*) timeout="${arg#--api-timeout=}" ;;
    --token-budget)
      has_token_budget=1
      next_is_token_budget=1
      ;;
    --token-budget=*)
      has_token_budget=1
      token_budget_value="${arg#--token-budget=}"
      ;;
    --max-concurrency)
      has_max_concurrency=1
      next_is_max_concurrency=1
      ;;
    --max-concurrency=*)
      has_max_concurrency=1
      max_concurrency_value="${arg#--max-concurrency=}"
      ;;
    --backend | --backend=*)
      die "lds graphify selects the Graphify backend from the active LLM provider; do not pass --backend"
      ;;
    --no-cluster)
      die "lds graphify already separates extraction and clustering; do not pass --no-cluster"
      ;;
    esac
  done

  ((next_is_model == 0)) || die "--model requires a value"
  ((next_is_timeout == 0)) || die "--api-timeout requires a value"
  ((next_is_token_budget == 0)) || die "--token-budget requires a value"
  ((next_is_max_concurrency == 0)) || die "--max-concurrency requires a value"

  [[ -n "$model" ]] || die "Graphify model cannot be empty"
  [[ "$timeout" =~ ^[0-9]+$ ]] && ((timeout >= 1)) ||
    die "GRAPHIFY_API_TIMEOUT/--api-timeout must be a positive integer"

  if ((has_token_budget)); then
    [[ "$token_budget_value" =~ ^[0-9]+$ ]] && ((token_budget_value >= 1)) ||
      die "--token-budget must be a positive integer"
  fi
  if ((has_max_concurrency)); then
    [[ "$max_concurrency_value" =~ ^[0-9]+$ ]] && ((max_concurrency_value >= 1)) ||
      die "--max-concurrency must be a positive integer"
  fi

  # Local models are more reliable with conservative semantic chunking and
  # serialized requests. Callers can still override both limits explicitly.
  if [[ "$provider" == fastflow ]] || ((local_provider)); then
    if ((has_token_budget == 0)); then
      token_budget_value="${LDS_GRAPHIFY_TOKEN_BUDGET:-4000}"
      [[ "$token_budget_value" =~ ^[0-9]+$ ]] && ((token_budget_value >= 1)) ||
        die "LDS_GRAPHIFY_TOKEN_BUDGET must be a positive integer"
      graphify_defaults+=(--token-budget "$token_budget_value")
    fi
    if ((has_max_concurrency == 0)); then
      max_concurrency_value="${LDS_GRAPHIFY_MAX_CONCURRENCY:-1}"
      [[ "$max_concurrency_value" =~ ^[0-9]+$ ]] && ((max_concurrency_value >= 1)) ||
        die "LDS_GRAPHIFY_MAX_CONCURRENCY must be a positive integer"
      graphify_defaults+=(--max-concurrency "$max_concurrency_value")
    fi
  fi

  ((local_provider == 0)) || _graphify_local_model_preflight "$model"

  graphify_bin="$(bin_path graphify)"
  target_abs="$target"
  provider_dir=""

  if ((local_provider)); then
    target_abs="$(_realpath "$target")"
    provider_dir="$(mktemp -d)" || die "Unable to create temporary Graphify provider directory"

    graphify_python="$(_graphify_python_bin "$graphify_bin")" ||
      die "Unable to find the Python interpreter required for LocalDevStack Graphify structured output"

    if [[ -d "$target_abs" ]]; then
      diagnostic_root="$target_abs"
    else
      diagnostic_root="$(dirname "$target_abs")"
    fi
    diagnostic_log="${LDS_GRAPHIFY_DIAGNOSTIC_LOG:-$diagnostic_root/graphify-out/lds-graphify-diagnostics.jsonl}"
    diagnostic_preview="${LDS_GRAPHIFY_DIAGNOSTIC_PREVIEW:-4096}"
    [[ "$diagnostic_preview" =~ ^[0-9]+$ ]] && ((diagnostic_preview >= 256)) ||
      die "LDS_GRAPHIFY_DIAGNOSTIC_PREVIEW must be an integer >= 256"

    if _graphify_diagnostics_enabled; then
      diagnostic_mode=on
    fi
  fi

  (
    proxy_pid=""
    cleanup_graphify_local() {
      if [[ -n "${proxy_pid:-}" ]]; then
        kill "$proxy_pid" >/dev/null 2>&1 || true
        wait "$proxy_pid" >/dev/null 2>&1 || true
      fi
      [[ -z "$provider_dir" ]] || rm -rf "$provider_dir"
    }
    [[ -z "$provider_dir" ]] || trap cleanup_graphify_local EXIT
    export GRAPHIFY_API_TIMEOUT="$timeout"

    if ((local_provider)); then
      local_provider_base_url="$base_url"

      if [[ -n "$graphify_python" ]]; then
        ready_file="$provider_dir/graphify-proxy.port"
        if [[ "$diagnostic_mode" == on ]]; then
          mkdir -p "$(dirname "$diagnostic_log")"
          : >"$diagnostic_log"
        fi

        "$graphify_python" "$DIR/scripts/graphify-diagnostic-proxy.py" \
          --upstream "${base_url%/v1}" \
          --provider "$provider" \
          --diagnostics "$diagnostic_mode" \
          --ready-file "$ready_file" \
          --log-file "$diagnostic_log" \
          --preview-chars "$diagnostic_preview" &
        proxy_pid=$!

        proxy_port=""
        for _ in {1..100}; do
          if [[ -s "$ready_file" ]]; then
            proxy_port="$(cat "$ready_file")"
            break
          fi
          kill -0 "$proxy_pid" >/dev/null 2>&1 ||
            die "Local Graphify structured-output proxy exited before becoming ready"
          sleep 0.05
        done
        [[ "$proxy_port" =~ ^[0-9]+$ ]] ||
          die "Local Graphify structured-output proxy did not become ready"

        local_provider_base_url="http://127.0.0.1:${proxy_port}/v1"
        if [[ "$diagnostic_mode" == on ]]; then
          printf '%s\n' "[lds graphify] suspect-response diagnostics enabled: $diagnostic_log" >&2
        fi
      fi

      backend="$(_graphify_write_local_provider "$provider_dir" "$provider" "$local_provider_base_url" "$model" "$token_budget_value" "$graphify_think")" ||
        die "Unable to build LocalDevStack Graphify provider configuration"

      unset OPENAI_BASE_URL OPENAI_API_KEY OPENAI_MODEL OLLAMA_BASE_URL OLLAMA_API_KEY OLLAMA_MODEL
      export LDS_GRAPHIFY_API_KEY=local
      export GRAPHIFY_ALLOW_LOCAL_PROVIDERS=1
      cd "$provider_dir"
    else
      case "$backend" in
      openai)
        unset OLLAMA_BASE_URL OLLAMA_API_KEY OLLAMA_MODEL
        export OPENAI_BASE_URL="$base_url"
        export OPENAI_API_KEY="$api_key"
        export OPENAI_MODEL="$model"
        ;;
      ollama)
        unset OPENAI_BASE_URL OPENAI_API_KEY OPENAI_MODEL
        export OLLAMA_BASE_URL="$base_url"
        export OLLAMA_API_KEY="$api_key"
        export OLLAMA_MODEL="$model"
        ;;
      esac
    fi

    "$graphify_bin" extract "$target_abs" --backend "$backend" --no-cluster "${graphify_defaults[@]}" "$@" &&
      "$graphify_bin" cluster-only "$target_abs" --backend "$backend"
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
      update_env "$ENV_DOCKER" LDS_AI_IGPU_ENABLE ""
      local detected
      detected="$(detect_ai_runtime)"
      ok "LLM runtime set to auto; detected $detected ($(ai_provider_for_runtime "$detected")). Recreate the AI service to apply it."
      ;;
    cpu | nvidia | amd | npu)
      local normalized igpu_enable provider image
      normalized="${mode,,}"
      igpu_enable="$(ai_igpu_default_for_runtime "$normalized")"
      provider="$(ai_provider_for_runtime "$normalized")"

      if [[ "$normalized" == "npu" ]] && ! fastflow_npu_supported; then
        warn "No FastFlow-supported XDNA2 NPU is currently detected; the explicit npu runtime will still be persisted."
      fi

      update_env "$ENV_DOCKER" LDS_AI_RUNTIME "$normalized"
      update_env "$ENV_DOCKER" LDS_AI_IGPU_ENABLE "$igpu_enable"

      if [[ "$provider" == "fastflow" ]]; then
        image="infocyph/llm-fastflow:latest"
      elif [[ "$normalized" == "amd" ]]; then
        image="infocyph/llm-ollama:amd-latest"
      else
        image="infocyph/llm-ollama:latest"
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

  think)
    local think_mode="${1:-}"
    if [[ -z "$think_mode" ]]; then
      local configured
      configured="$(compose_control_value LDS_AI_THINK "")"
      printf '%s\n' "${configured:-auto}"
      return 0
    fi
    [[ $# -eq 1 ]] || die "llm think <auto|on|off>"
    case "${think_mode,,}" in
    auto | default)
      remove_env "$ENV_DOCKER" LDS_AI_THINK
      ok "LLM thinking override cleared; provider/model default will be used after the AI service is recreated."
      ;;
    on | true | 1)
      update_env "$ENV_DOCKER" LDS_AI_THINK true
      ok "LLM thinking forced on. Recreate the AI service to apply the change."
      ;;
    off | false | 0)
      update_env "$ENV_DOCKER" LDS_AI_THINK false
      ok "LLM thinking forced off. Recreate the AI service to apply the change."
      ;;
    *) die "llm think <auto|on|off>" ;;
    esac
    ;;

  provider)
    printf '%s\n' "$(_active_llm_provider)"
    ;;

  help | -h | --help)
    printf '%s\n' "llm <models|pull|rm|run|ask|chat|prompt|code|review|json|ai-commit|api|version>"
    printf '%s\n' "llm provider"
    printf '%s\n' "llm runtime <auto|cpu|nvidia|amd|npu>"
    printf '%s\n' "llm think <auto|on|off>"
    printf '%s\n' "Ollama-only: llm <ps|show|unload|ollama>"
    printf '%s\n' "FastFlow-only: llm <validate|check|flm>"
    ;;

  *) die "llm <models|pull|rm|run|ask|chat|prompt|code|review|json|ai-commit|api|version|provider|runtime|think>" ;;
  esac
}
