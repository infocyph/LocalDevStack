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
  explain | troubleshoot | review | document-review | repo-review | graphify)
    _tools_exec_argv aiops "${sub,,}" "$@"
    ;;
  *) die "ai <status|ask|explain|troubleshoot|review|document-review|repo-review|graphify> [args...]" ;;
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
  local dir="$1" provider="$2" base_url="$3" model="$4" token_budget="$5" think_mode="${6:-off}" output_budget="${7:-8192}"
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
        --argjson output_budget "$output_budget" \
        '{
          ($backend): {
            base_url: $base_url,
            default_model: $model,
            env_key: "LDS_GRAPHIFY_API_KEY",
            max_tokens: $output_budget,
            extra_body: {think: false}
          }
        }' >"$dir/.graphify/providers.json"
      ;;
    on)
      jq -n \
        --arg backend "$backend" \
        --arg base_url "$base_url" \
        --arg model "$model" \
        --argjson output_budget "$output_budget" \
        '{
          ($backend): {
            base_url: $base_url,
            default_model: $model,
            env_key: "LDS_GRAPHIFY_API_KEY",
            max_tokens: $output_budget,
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
        --argjson output_budget "$output_budget" \
        '{
          ($backend): {
            base_url: $base_url,
            default_model: $model,
            env_key: "LDS_GRAPHIFY_API_KEY",
            max_tokens: $output_budget
          }
        }' >"$dir/.graphify/providers.json"
      ;;
    *) return 1 ;;
    esac
    ;;
  ollama)
    num_ctx=$((token_budget + output_budget + 4096))
    ((num_ctx < 16384)) && num_ctx=16384
    ((num_ctx > 131072)) && num_ctx=131072
    num_ctx=$((((num_ctx + 1023) / 1024) * 1024))
    jq -n \
      --arg backend "$backend" \
      --arg base_url "$base_url" \
      --arg model "$model" \
      --argjson num_ctx "$num_ctx" \
      --argjson output_budget "$output_budget" \
      '{
        ($backend): {
          base_url: $base_url,
          default_model: $model,
          env_key: "LDS_GRAPHIFY_API_KEY",
          max_tokens: $output_budget,
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

_graphify_version_preflight() {
  local graphify_bin="${1:-graphify}" version min_version="${LDS_GRAPHIFY_MIN_VERSION:-0.9.65}"
  local v_major v_minor v_patch m_major m_minor m_patch

  [[ "$min_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "LDS_GRAPHIFY_MIN_VERSION must use MAJOR.MINOR.PATCH format."

  version="$("$graphify_bin" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  [[ -n "$version" ]] ||
    die "Unable to determine Graphify version. LocalDevStack requires graphifyy >= $min_version."

  IFS=. read -r v_major v_minor v_patch <<<"$version"
  IFS=. read -r m_major m_minor m_patch <<<"$min_version"
  if ((v_major < m_major)) ||
    ((v_major == m_major && v_minor < m_minor)) ||
    ((v_major == m_major && v_minor == m_minor && v_patch < m_patch)); then
    die "Graphify $version is too old. LocalDevStack requires graphifyy >= $min_version."
  fi
}

_graphify_has_graph() {
  local target="${1:-.}"
  [[ -d "$target" && -f "$target/graphify-out/graph.json" ]]
}

_graphify_has_incremental_state() {
  local target="${1:-.}"
  [[ -d "$target" && -f "$target/graphify-out/graph.json" && -f "$target/graphify-out/manifest.json" ]]
}

_graphify_docstruct_mode() {
  case "${LDS_GRAPHIFY_DOCSTRUCT:-auto}" in
  auto | on | off) printf '%s' "${LDS_GRAPHIFY_DOCSTRUCT:-auto}" ;;
  *) die "LDS_GRAPHIFY_DOCSTRUCT must be auto, on, or off" ;;
  esac
}

_graphify_doc_review_mode() {
  case "${LDS_GRAPHIFY_DOC_REVIEW:-auto}" in
  auto | on | off) printf '%s' "${LDS_GRAPHIFY_DOC_REVIEW:-auto}" ;;
  *) die "LDS_GRAPHIFY_DOC_REVIEW must be auto, on, or off" ;;
  esac
}

_graphify_docstruct_available() {
  local output
  output="$(docker_compose run --rm --no-deps -T server-tools docstruct graphify-merge --help 2>/dev/null)" ||
    return 1
  grep -Fq 'Usage: docstruct graphify-merge' <<<"$output"
}

_graphify_docstruct_enrich() {
  local graphify_bin="$1" target_abs="$2" review_mode="$3"
  shift 3
  local workdir review_file="" rc=0
  local -a review_args=()

  workdir="$(mktemp -d "${TMPDIR:-/tmp}/lds-graphify-docstruct.XXXXXX")" ||
    die "Unable to create temporary document-extraction directory"
  chmod 700 "$workdir" 2>/dev/null || true

  printf '%s\n' "[lds graphify] documents: extracting Markdown/RST/config structure deterministically" >&2
  if ! docker_compose run --rm --no-deps -T \
    -v "$target_abs:/workspace:ro" \
    -v "$workdir:/docstruct:rw" \
    server-tools docstruct /workspace --compact --output /docstruct/docstruct.json "$@"; then
    rm -rf "$workdir"
    die "Deterministic document extraction failed"
  fi

  if [[ "$review_mode" != off ]]; then
    printf '%s\n' "[lds graphify] documents: reviewing bounded semantic chunks with the active local model" >&2
    if docker_compose run --rm --no-deps -T \
      -e DOCSTRUCT_REVIEW_ROOT=/workspace \
      -v "$target_abs:/workspace:ro" \
      -v "$workdir:/docstruct:rw" \
      server-tools aiops document-review --file /docstruct/docstruct.json >"$workdir/review.json"; then
      review_file="/docstruct/review.json"
      review_args=(--review "$review_file")
    elif [[ "$review_mode" == on ]]; then
      rm -rf "$workdir"
      die "Document semantic review failed while LDS_GRAPHIFY_DOC_REVIEW=on"
    else
      warn "Document semantic review failed; continuing with deterministic structure only."
      rm -f "$workdir/review.json"
    fi
  fi

  if ! docker_compose run --rm --no-deps -T \
    -v "$workdir:/docstruct:rw" \
    server-tools docstruct graphify /docstruct/docstruct.json \
      --source-root "$target_abs" "${review_args[@]}" --compact --output /docstruct/fragment.json; then
    rm -rf "$workdir"
    die "Unable to convert deterministic document structure to a Graphify fragment"
  fi

  # Use Graphify's public validator before mutating graph.json. The validated
  # output itself is disposable because docstruct ownership metadata is needed
  # by the deterministic replacement merge below.
  if ! "$graphify_bin" merge-chunks "$workdir/fragment.json" --out "$workdir/validated.json" >/dev/null; then
    rm -rf "$workdir"
    die "Graphify rejected the deterministic document fragment"
  fi

  printf '%s\n' "[lds graphify] documents: replacing the supported non-code semantic layer" >&2
  if ! docker_compose run --rm --no-deps -T \
    -v "$target_abs/graphify-out:/graphify:ro" \
    -v "$workdir:/docstruct:rw" \
    server-tools docstruct graphify-merge \
      /graphify/graph.json /docstruct/fragment.json --output /docstruct/merged-graph.json; then
    rc=$?
    rm -rf "$workdir"
    return "$rc"
  fi

  # Publish from the host so graph.json stays owned by the invoking user. A
  # root-owned one-shot Tools container must never replace host Graphify output
  # directly or the subsequent host-side Graphify label step cannot reopen it.
  local graph_path="$target_abs/graphify-out/graph.json" publish_tmp
  publish_tmp="$(mktemp "$target_abs/graphify-out/.graph.json.docstruct.XXXXXX")" || {
    rm -rf "$workdir"
    die "Unable to create temporary Graphify output for document merge"
  }
  if ! cat "$workdir/merged-graph.json" >"$publish_tmp"; then
    rm -f "$publish_tmp"
    rm -rf "$workdir"
    die "Unable to stage merged Graphify output"
  fi
  chmod 0644 "$publish_tmp" 2>/dev/null || true
  if ! mv -f "$publish_tmp" "$graph_path"; then
    rm -f "$publish_tmp"
    rm -rf "$workdir"
    die "Unable to publish merged Graphify output"
  fi

  rm -rf "$workdir"
}

cmd_graphify() {
  need_bin graphify "install the Graphify CLI on the host first"

  local target="${1:-.}"
  [[ $# -eq 0 ]] || shift
  [[ -e "$target" ]] || die "Graphify target does not exist: $target"

  local runtime provider backend base_url timeout model api_key graphify_bin arg provider_dir target_abs graphify_target
  local graphify_think="off"
  local structured_output_tokens="" graphify_sdk_retries="" graphify_retry_depth=""
  local local_provider=0 force_rebuild=0 explicit_code_only=0 bootstrap_code_first=0 docstruct_enabled=0
  local next_is_model=0 next_is_timeout=0 next_is_token_budget=0 next_is_max_concurrency=0 next_is_exclude=0
  local has_token_budget=0 has_max_concurrency=0
  local token_budget_value="" max_concurrency_value="" docstruct_mode="" doc_review_mode=""
  local -a graphify_defaults=() graphify_cluster_defaults=() docstruct_scan_args=()
  local -a docstruct_graphify_excludes=(
    --exclude '*.md' --exclude '*.markdown' --exclude '*.rst'
    --exclude '*.yaml' --exclude '*.yml' --exclude '*.json'
    --exclude '*.toml' --exclude '*.ini' --exclude '*.cfg'
    --exclude 'requirements*.txt' --exclude 'constraints*.txt'
    --exclude 'requirements/*.txt' --exclude '**/requirements/*.txt'
  )

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

  structured_output_tokens="${GRAPHIFY_MAX_OUTPUT_TOKENS:-${LDS_GRAPHIFY_OUTPUT_TOKENS:-8192}}"
  [[ "$structured_output_tokens" =~ ^[0-9]+$ ]] && ((structured_output_tokens >= 512)) ||
    die "LDS_GRAPHIFY_OUTPUT_TOKENS must be an integer >= 512"

  graphify_sdk_retries="${GRAPHIFY_MAX_RETRIES:-${LDS_GRAPHIFY_SDK_RETRIES:-0}}"
  [[ "$graphify_sdk_retries" =~ ^[0-9]+$ ]] ||
    die "GRAPHIFY_MAX_RETRIES/LDS_GRAPHIFY_SDK_RETRIES must be a non-negative integer"

  graphify_retry_depth="${GRAPHIFY_MAX_RETRY_DEPTH:-${LDS_GRAPHIFY_MAX_RETRY_DEPTH:-2}}"
  [[ "$graphify_retry_depth" =~ ^[0-9]+$ ]] ||
    die "GRAPHIFY_MAX_RETRY_DEPTH/LDS_GRAPHIFY_MAX_RETRY_DEPTH must be a non-negative integer"

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
    if ((next_is_exclude)); then
      docstruct_scan_args+=(--exclude "$arg")
      next_is_exclude=0
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
    --exclude)
      next_is_exclude=1
      ;;
    --exclude=*)
      docstruct_scan_args+=(--exclude "${arg#--exclude=}")
      ;;
    --no-gitignore)
      docstruct_scan_args+=(--no-gitignore)
      ;;
    --force)
      force_rebuild=1
      ;;
    --code-only)
      explicit_code_only=1
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
  ((next_is_exclude == 0)) || die "--exclude requires a value"

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
      token_budget_value="${LDS_GRAPHIFY_TOKEN_BUDGET:-3000}"
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

  if [[ -n "$max_concurrency_value" ]]; then
    graphify_cluster_defaults+=(--max-concurrency "$max_concurrency_value")
  fi

  ((local_provider == 0)) || _graphify_local_model_preflight "$model"

  graphify_bin="$(bin_path graphify)"
  _graphify_version_preflight "$graphify_bin"
  target_abs="$(_realpath "$target")"
  graphify_target="$target"
  provider_dir=""

  docstruct_mode="$(_graphify_docstruct_mode)"
  doc_review_mode="$(_graphify_doc_review_mode)"
  if ((explicit_code_only == 0)) && [[ "$docstruct_mode" != off ]]; then
    if _graphify_docstruct_available; then
      docstruct_enabled=1
    elif [[ "$docstruct_mode" == on ]]; then
      die "LDS_GRAPHIFY_DOCSTRUCT=on requires a docker-tools image with docstruct Graphify merge support"
    else
      warn "docker-tools docstruct integration is unavailable; falling back to Graphify semantic extraction."
    fi
  fi

  if ((docstruct_enabled)) && ((local_provider == 0)); then
    if [[ "$doc_review_mode" == on ]]; then
      die "LDS_GRAPHIFY_DOC_REVIEW=on requires the built-in LocalDevStack AI provider route"
    fi
    [[ "$doc_review_mode" == auto ]] && doc_review_mode=off
  fi

  if _graphify_has_incremental_state "$target_abs"; then
    if ((force_rebuild)); then
      printf '%s\n' "[lds graphify] existing graph detected; --force requested, performing a full rebuild" >&2
    else
      printf '%s\n' "[lds graphify] existing graph detected; using Graphify incremental update (changed files only)" >&2
    fi
  elif _graphify_has_graph "$target_abs"; then
    printf '%s\n' "[lds graphify] existing graph detected without complete manifest; letting Graphify recover from the graph baseline" >&2
  elif ((explicit_code_only)); then
    printf '%s\n' "[lds graphify] no graph detected; performing requested code-only build" >&2
  elif ((force_rebuild)); then
    printf '%s\n' "[lds graphify] no graph detected; --force requested, performing a full build" >&2
  else
    bootstrap_code_first=1
    printf '%s\n' "[lds graphify] no graph detected; bootstrapping code-first before semantic enrichment" >&2
  fi

  if ((local_provider)); then
    graphify_target="$target_abs"
    provider_dir="$(mktemp -d)" || die "Unable to create temporary Graphify provider directory"
  fi

  (
    cleanup_graphify_local() {
      [[ -z "$provider_dir" ]] || rm -rf "$provider_dir"
    }
    [[ -z "$provider_dir" ]] || trap cleanup_graphify_local EXIT
    export GRAPHIFY_API_TIMEOUT="$timeout"

    if ((local_provider)); then
      export GRAPHIFY_MAX_RETRIES="$graphify_sdk_retries"
      export GRAPHIFY_MAX_RETRY_DEPTH="$graphify_retry_depth"
      export GRAPHIFY_MAX_OUTPUT_TOKENS="$structured_output_tokens"

      backend="$(_graphify_write_local_provider "$provider_dir" "$provider" "$base_url" "$model" "$token_budget_value" "$graphify_think" "$structured_output_tokens")" ||
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

    if ((docstruct_enabled)); then
      if ((bootstrap_code_first)); then
        printf '%s\n' "[lds graphify] phase 1/3: extracting code structure first" >&2
        "$graphify_bin" extract "$graphify_target" --backend "$backend" --no-cluster --code-only "${graphify_defaults[@]}" "$@" &&
          printf '%s\n' "[lds graphify] phase 2/3: extracting only semantic formats not owned by docstruct" >&2 &&
          "$graphify_bin" extract "$graphify_target" --backend "$backend" --no-cluster "${graphify_defaults[@]}" "${docstruct_graphify_excludes[@]}" "$@" &&
          printf '%s\n' "[lds graphify] phase 3/3: merging deterministic document structure and relabeling" >&2 &&
          _graphify_docstruct_enrich "$graphify_bin" "$target_abs" "$doc_review_mode" "${docstruct_scan_args[@]}" &&
          "$graphify_bin" label "$graphify_target" --backend "$backend" "${graphify_cluster_defaults[@]}"
      else
        printf '%s\n' "[lds graphify] extracting changed code/unsupported semantic inputs; supported docs use docstruct" >&2
        "$graphify_bin" extract "$graphify_target" --backend "$backend" --no-cluster "${graphify_defaults[@]}" "${docstruct_graphify_excludes[@]}" "$@" &&
          _graphify_docstruct_enrich "$graphify_bin" "$target_abs" "$doc_review_mode" "${docstruct_scan_args[@]}" &&
          "$graphify_bin" label "$graphify_target" --backend "$backend" "${graphify_cluster_defaults[@]}"
      fi
    elif ((bootstrap_code_first)); then
      printf '%s\n' "[lds graphify] phase 1/2: extracting code structure and clustering the structural graph" >&2
      "$graphify_bin" extract "$graphify_target" --backend "$backend" --no-cluster --code-only "${graphify_defaults[@]}" "$@" &&
        "$graphify_bin" cluster-only "$graphify_target" --backend "$backend" "${graphify_cluster_defaults[@]}" &&
        printf '%s\n' "[lds graphify] phase 2/2: enriching the existing graph with semantic files" >&2 &&
        "$graphify_bin" extract "$graphify_target" --backend "$backend" --no-cluster "${graphify_defaults[@]}" "$@" &&
        "$graphify_bin" label "$graphify_target" --backend "$backend" "${graphify_cluster_defaults[@]}"
    else
      "$graphify_bin" extract "$graphify_target" --backend "$backend" --no-cluster "${graphify_defaults[@]}" "$@" &&
        "$graphify_bin" cluster-only "$graphify_target" --backend "$backend" "${graphify_cluster_defaults[@]}"
    fi
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
