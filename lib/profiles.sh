# shellcheck shell=bash
###############################################################################
# 3a. PROFILES: DEFINITIONS + SETUP FLOW
###############################################################################

CATALOG_FILE="$CFG/catalog/services.psv"

declare -A SERVICES=()
declare -A SERVICE_DISPLAY=()
declare -A SERVICE_KEY=()
declare -A SERVICE_VERSION_ENV=()
declare -A PROFILE_ENV=()
declare -A PROFILE_PROMPTS=()
declare -A SERVICE_ADMIN_CLIENT=()
declare -A SERVICE_VOLUME=()
declare -A SERVICE_URL=()
declare -A SERVICE_CATEGORY=()
declare -A SERVICE_OPTIONAL=()
declare -A SERVICE_DEFAULT_ENABLED=()
declare -A SERVICE_RUNTIME_MODES=()
declare -a SERVICE_ORDER=()

load_service_catalog() {
  [[ -r "$CATALOG_FILE" ]] || die "Missing service catalog: $CATALOG_FILE"

  local key profile display service_key version_env defaults prompts
  local admin_client volume url category optional default_enabled runtime_modes

  while IFS='|' read -r key profile display service_key version_env defaults prompts admin_client volume url category optional default_enabled runtime_modes; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    [[ -n "$profile" && -n "$display" && -n "$service_key" ]] ||
      die "Invalid service catalog row for: $key"
    [[ -z "${SERVICES[$key]+x}" ]] || die "Duplicate service catalog key: $key"
    [[ -z "${PROFILE_ENV[$profile]+x}" ]] || die "Duplicate service catalog profile: $profile"

    SERVICE_ORDER+=("$key")
    SERVICES["$key"]="$profile"
    SERVICE_DISPLAY["$key"]="$display"
    SERVICE_KEY["$key"]="$service_key"
    SERVICE_VERSION_ENV["$key"]="$version_env"
    PROFILE_ENV["$profile"]="$defaults"
    PROFILE_PROMPTS["$profile"]="$prompts"
    SERVICE_ADMIN_CLIENT["$key"]="$admin_client"
    SERVICE_VOLUME["$key"]="$volume"
    SERVICE_URL["$key"]="$url"
    SERVICE_CATEGORY["$key"]="$category"
    SERVICE_OPTIONAL["$key"]="$optional"
    SERVICE_DEFAULT_ENABLED["$key"]="$default_enabled"
    SERVICE_RUNTIME_MODES["$key"]="$runtime_modes"
  done <"$CATALOG_FILE"

  (("${#SERVICE_ORDER[@]}" > 0)) || die "Service catalog is empty: $CATALOG_FILE"
}

load_service_catalog

declare -a PENDING_ENVS=()
declare -a PENDING_PROFILES=()

queue_env() { PENDING_ENVS+=("$1"); }
queue_profile() { PENDING_PROFILES+=("$1"); }

flush_envs() {
  local env_file="$ENV_DOCKER" kv key val
  for kv in "${PENDING_ENVS[@]}"; do
    IFS='=' read -r key val <<<"$kv"
    update_env "$env_file" "$key" "$val"
  done
}

flush_profiles() {
  local current key profile
  local -A managed=() seen=()
  local -a existing=() updated=()

  # The setup wizard owns only catalog-managed service profiles. Generated
  # runtime/domain profiles (for example apache/php/node fragments) must survive
  # a service-profile reselection.
  for key in "${SERVICE_ORDER[@]}"; do
    profile="${SERVICES[$key]:-}"
    [[ -n "$profile" ]] && managed["$profile"]=1
  done

  for profile in "${PENDING_PROFILES[@]}"; do
    [[ -n "$profile" && -z "${seen[$profile]:-}" ]] || continue
    updated+=("$profile")
    seen["$profile"]=1
  done

  current="$(dotenv_value "$ENV_DOCKER" COMPOSE_PROFILES 2>/dev/null || true)"
  IFS=',' read -r -a existing <<<"$current"
  for profile in "${existing[@]}"; do
    profile="${profile//[[:space:]]/}"
    [[ -n "$profile" ]] || continue
    [[ -n "${managed[$profile]:-}" ]] && continue
    [[ -n "${seen[$profile]:-}" ]] && continue
    updated+=("$profile")
    seen["$profile"]=1
  done

  local joined=""
  if (("${#updated[@]}" > 0)); then
    joined="$(IFS=,; printf '%s' "${updated[*]}")"
  fi
  update_env "$ENV_DOCKER" COMPOSE_PROFILES "$joined"
}

# ── setup menu (selection-first) ──────────────────────────────────────────────

setup_menu_print() {
  # Print menu to stderr to avoid stdout buffering in some Windows wrappers.
  {
    printf "\n%bSetup profiles%b (replaces catalog-managed service profiles; generated runtime/domain profiles are preserved):\n\n" "$CYAN" "$NC"
    local i=1 key slug display
    for key in "${SERVICE_ORDER[@]}"; do
      slug="${SERVICES[$key]}"
      display="${SERVICE_DISPLAY[$key]}"
      printf "  %2d) %-16s  (%s)\n" "$i" "$display" "$slug"
      i=$((i + 1))
    done
    printf "\n  a) ALL\n"
    printf "  n) NONE / Back\n\n"
  } >&2
}

# Parse user selection into indices or ALL/NONE/CANCEL (prints one token per line)
setup_menu_parse() {
  local input="${1//[[:space:]]/}"
  [[ -n "$input" ]] || return 1
  input="${input//;/,}"

  echo "$input" | tr ',' '\n' | awk '
    BEGIN { ok=1 }
    /^[0-9]+-[0-9]+$/ {
      split($0,a,"-")
      if (a[1] > a[2]) { t=a[1]; a[1]=a[2]; a[2]=t }
      for (i=a[1]; i<=a[2]; i++) print i
      next
    }
    /^[0-9]+$/ { print $0; next }
    /^[aA]$/ { print "ALL"; next }
    /^[nN]$/ { print "NONE"; next }
    { ok=0 }
    END { if (!ok) exit 2 }
  '
}

# Outputs: newline-separated service KEYS from SERVICE_ORDER (e.g. MYSQL, REDIS)
setup_choose_services() {
  local ans parsed
  while :; do
    setup_menu_print
    tty_readline ans "Select (e.g. 1,3,5 or 2-4 or a): " || return 1

    if ! parsed="$(setup_menu_parse "$ans" 2>/dev/null)"; then
      printf "%bInvalid selection.%b Try again.\n" "$YELLOW" "$NC"
      continue
    fi

    if grep -qx "CANCEL" <<<"$parsed"; then
      return 1
    fi

    if grep -qx "NONE" <<<"$parsed"; then
      printf '%s\n' "__NONE__"
      return 0
    fi

    if grep -qx "ALL" <<<"$parsed"; then
      printf "%s\n" "${SERVICE_ORDER[@]}"
      return 0
    fi

    # Indices -> keys (de-dupe, preserve order)
    local -A seen=()
    local out=()
    local idx key
    while IFS= read -r idx; do
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      ((idx >= 1 && idx <= ${#SERVICE_ORDER[@]})) || continue
      key="${SERVICE_ORDER[idx - 1]}"
      [[ -n "${seen[$key]:-}" ]] && continue
      seen[$key]=1
      out+=("$key")
    done <<<"$parsed"

    if ((${#out[@]} == 0)); then
      printf "%bNo valid items selected.%b\n" "$YELLOW" "$NC"
      continue
    fi

    printf "%s\n" "${out[@]}"
    return 0
  done
}

setup_service() {
  local service="$1"
  local profile="${SERVICES[$service]:-}"
  local display="${SERVICE_DISPLAY[$service]:-$service}"
  [[ -n "$profile" ]] || die "Unknown service: $service"

  printf "\n%b→ %s%b\n" "$YELLOW" "$display" "$NC"
  queue_profile "$profile"

  if [[ "$service" == "AI" ]]; then
    local detected_runtime detected_arch
    detected_runtime="$(compose_control_value LDS_AI_RUNTIME "$(detect_ai_runtime)")"
    detected_arch="$(llm_arch_for_runtime "$detected_runtime")"
    printf "%bDetected local-AI runtime:%b %s (%s)\n" "$CYAN" "$NC" "$detected_runtime" "infocyph/llm-ollama:$detected_arch"
  fi

  local defaults="${PROFILE_ENV[$profile]:-}"
  [[ -n "$defaults" ]] || return 0

  printf "%bEnter value(s) for %s:%b\n" "$BLUE" "$display" "$NC"

  local -a pairs=() prompts=()
  IFS=';' read -r -a pairs <<<"$defaults"
  IFS=';' read -r -a prompts <<<"${PROFILE_PROMPTS[$profile]:-}"

  local i pair key def val prompt current input
  for i in "${!pairs[@]}"; do
    pair="${pairs[$i]}"
    [[ -n "$pair" ]] || continue
    IFS='=' read -r key def <<<"$pair"
    prompt="${prompts[$i]:-$key}"
    current="$(dotenv_value "$ENV_DOCKER" "$key" 2>/dev/null || true)"

    # Re-running setup must not reset a user's selected versions or credentials.
    # Secret-like values are preserved without printing their current/default value.
    case "$key" in
    *PASSWORD* | *SECRET* | *TOKEN* | *PRIVATE_KEY* | *API_KEY* | *ACCESS_KEY*)
      if [[ -n "$current" ]]; then
        tty_readline input "$(printf '%b%s [configured; Enter keeps current]:%b ' "$CYAN" "$prompt" "$NC")" || return 1
        val="${input:-$current}"
      else
        tty_readline input "$(printf '%b%s [Enter uses catalog default]:%b ' "$CYAN" "$prompt" "$NC")" || return 1
        val="${input:-$def}"
      fi
      ;;
    *)
      val="$(read_default "$prompt" "${current:-$def}")"
      ;;
    esac

    case "$key" in
    LDS_AI_RUNTIME)
      val="${val,,}"
      case "$val" in
      cpu | nvidia | amd) ;;
      *) die "AI runtime must be cpu, nvidia, or amd" ;;
      esac
      ;;
    esac

    queue_env "$key=$val"
  done
}

process_all() {
  local selected
  PENDING_ENVS=()
  PENDING_PROFILES=()

  if ! selected="$(setup_choose_services)"; then
    printf "\n%bSetup cancelled.%b\n" "$YELLOW" "$NC"
    return 0
  fi

  if [[ "$selected" == "__NONE__" ]]; then
    flush_profiles
    printf "\n%b✅ Catalog-managed service profiles cleared; generated runtime/domain profiles preserved.%b\n" "$GREEN" "$NC"
    return 0
  fi

  printf "\n%bWill configure:%b\n" "$CYAN" "$NC"
  while IFS= read -r svc; do
    printf "  - %s (%s)\n" "${SERVICE_DISPLAY[$svc]:-$svc}" "${SERVICES[$svc]}"
  done <<<"$selected"
  echo

  local svc
  while IFS= read -r svc; do
    setup_service "$svc"
  done <<<"$selected"

  flush_envs
  flush_profiles
  printf "\n%b✅ Selected services configured!%b\n" "$GREEN" "$NC"
}

