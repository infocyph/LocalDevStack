###############################################################################
# 1a. DOCKER COMPOSE WRAPPER
###############################################################################

# ── compose extras (docker/extras/*.y{a,}ml) ────────────────────────────────
__EXTRAS_LOADED=0
declare -a __EXTRA_FILES=()

load_extras() {
  # Set LDS_EXTRAS_RELOAD=1 (or global --reload-extras) to re-scan templates every call.
  if [[ "${LDS_EXTRAS_RELOAD:-0}" == "1" ]]; then
    __EXTRAS_LOADED=0
  fi

  ((__EXTRAS_LOADED)) && return 0
  __EXTRAS_LOADED=1

  [[ -d "$EXTRAS_DIR" ]] || return 0

  mapfile -t __EXTRA_FILES < <(
    find "$EXTRAS_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null | sort | sed '/^[[:space:]]*$/d'
  )
}

docker_compose() {
  load_extras
  # Create required runtime files only when docker/compose operations are invoked.
  ((EUID == 0)) || ensure_files_exist "/docker/.env" "/configuration/php/php.ini" "/.env"
  if [[ -z "${__LDS_DC_BIN:-}" ]]; then
    if docker compose version >/dev/null 2>&1; then
      __LDS_DC_BIN=(docker compose)
    else
      __LDS_DC_BIN=(docker-compose)
    fi
  fi

  [[ -r "$ENV_RELEASE" ]] || die "Missing release compatibility manifest: $ENV_RELEASE"

  # Release defaults are loaded first; user docker/.env overrides them.
  # Shell variables remain higher-precedence Compose interpolation inputs.
  local -a env_files=(--env-file "$ENV_RELEASE")
  [[ -r "$ENV_DOCKER" ]] && env_files+=(--env-file "$ENV_DOCKER")

  local ai_runtime ai_host_port
  local -a static_f=()

  ai_runtime="$(compose_control_value LDS_AI_RUNTIME cpu)"
  case "${ai_runtime,,}" in
  "" | cpu) ;;
  nvidia) static_f+=(-f "$CFG/compose/ai-nvidia.yaml") ;;
  amd) static_f+=(-f "$CFG/compose/ai-amd.yaml") ;;
  *) die "Invalid LDS_AI_RUNTIME: $ai_runtime (expected cpu|nvidia|amd)" ;;
  esac

  ai_host_port="$(compose_control_value LDS_LLM_HOST_PORT 0)"
  case "${ai_host_port,,}" in
  "" | 0 | false | no | off) ;;
  1 | true | yes | on) static_f+=(-f "$CFG/compose/ai-host-port.yaml") ;;
  *) die "Invalid LDS_LLM_HOST_PORT: $ai_host_port (expected 0|1)" ;;
  esac

  # Product overrides are applied before user-provided compose extras.
  local -a extra_f=() f
  for f in "${__EXTRA_FILES[@]:-}"; do
    [[ -f "$f" ]] || continue
    case "$f" in
    *.yml | *.yaml) extra_f+=(-f "$f") ;;
    esac
  done

  local host_os="${HOST_OS:-$(detect_host_os)}"

  HOST_OS="$host_os" "${__LDS_DC_BIN[@]}" \
    --project-directory "$DIR" \
    -f "$COMPOSE_FILE" \
    "${static_f[@]}" \
    "${extra_f[@]}" \
    "${env_files[@]}" \
    "$@"
}

# helper: print project name
lds_project() { printf '%s' "${__LDS_PROJECT:-$(basename -- "$DIR")}"; }

# (QUIET by default) ────────────────────────────────
# Centralize quiet/verbose handling for compose subcommands.
# Usage: dc_cmd <up|pull|build> [args...]
dc_cmd() {
  local sub="${1:-}"
  shift || true

  local -a quiet=()
  if ((VERBOSE == 0)); then
    case "$sub" in
    up) quiet+=(--quiet-pull) ;;
    pull) quiet+=(-q) ;;
    build) quiet+=(--quiet) ;;
    esac
  fi

  docker_compose "$sub" "${quiet[@]}" "$@"
}

dc_up() { dc_cmd up "$@"; }
dc_pull() { dc_cmd pull "$@"; }
dc_build() {
  local scriptomatic_ref
  scriptomatic_ref="$(compose_control_value SCRIPTOMATIC_REF main)"
  [[ "$scriptomatic_ref" == "main" || "$scriptomatic_ref" =~ ^[0-9A-Fa-f]{40}$ ]] ||
    die "SCRIPTOMATIC_REF must be main or a full 40-character commit SHA"
  dc_cmd build --build-arg "SCRIPTOMATIC_REF=$scriptomatic_ref" "$@"
}

# helper for our own minimal logging (still shows in quiet mode)
logv() { ((VERBOSE)) && printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2 || true; }
logq() { printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2; }

