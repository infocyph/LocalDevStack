# shellcheck shell=bash
###############################################################################
# Compose helpers for rebuild (robust: supports service key OR container name)
###############################################################################
__COMPOSE_CFG_JSON=""
__COMPOSE_CFG_YAML=""
__COMPOSE_SVCS_LOADED=0
declare -a __COMPOSE_SVCS=()

compose_cfg_json() {
  if [[ -z "${__COMPOSE_CFG_JSON}" ]]; then
    __COMPOSE_CFG_JSON="$(docker_compose config --format json 2>/dev/null || true)"
  fi
  printf '%s' "${__COMPOSE_CFG_JSON}"
}

compose_cfg_yaml() {
  if [[ -z "${__COMPOSE_CFG_YAML}" ]]; then
    __COMPOSE_CFG_YAML="$(docker_compose config 2>/dev/null || true)"
  fi
  printf '%s' "${__COMPOSE_CFG_YAML}"
}

compose_services_load() {
  ((__COMPOSE_SVCS_LOADED)) && return 0
  mapfile -t __COMPOSE_SVCS < <(docker_compose config --services 2>/dev/null || true)
  __COMPOSE_SVCS_LOADED=1
}

compose_service_exists() {
  local want="${1:-}" s
  [[ -n "$want" ]] || return 1
  compose_services_load
  for s in "${__COMPOSE_SVCS[@]}"; do
    [[ "$s" == "$want" ]] && return 0
  done
  return 1
}

resolve_service() {
  local raw="${1:-}" norm svc
  raw="${raw//[[:space:]]/}"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }

  compose_service_exists "$raw" && {
    printf '%s' "$raw"
    return 0
  }

  # "llm" is the stable operational alias for whichever mutually-exclusive
  # provider is active for the effective runtime.
  if [[ "${raw,,}" == "llm" ]]; then
    norm="$(ai_service_for_runtime "$(effective_ai_runtime)")" ||
      die "Unable to resolve the active LLM provider service"
    compose_service_exists "$norm" || die "Active LLM provider service is unavailable: $norm"
    printf '%s' "$norm"
    return 0
  fi

  norm="$(normalize_service "$raw")"
  compose_service_exists "$norm" && {
    printf '%s' "$norm"
    return 0
  }

  if docker inspect "$raw" >/dev/null 2>&1; then
    svc="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$raw" 2>/dev/null || true)"
    if [[ -n "$svc" ]] && compose_service_exists "$svc"; then
      printf '%s' "$svc"
      return 0
    fi
  fi

  printf '%s' "$norm"
}

compose_has_build() {
  local svc="$1" json
  json="$(compose_cfg_json)"
  if [[ -n "$json" ]]; then
    if has_tool jq; then
      jq -e --arg s "$svc" '.services[$s].build != null' >/dev/null <<<"$json"
      return $?
    fi
  fi

  compose_cfg_yaml | awk -v s="$svc" '
    $1=="services:" {in_services=1; next}
    in_services && $0 ~ ("^  " s ":$") {in_svc=1; next}
    in_svc && $0 ~ /^  [A-Za-z0-9_.-]+:$/ {exit 1}
    in_svc && $0 ~ /^    build:/ {exit 0}
    END {exit 1}
  '
}

compose_image_for_service() {
  local svc="$1" json
  json="$(compose_cfg_json)"
  if [[ -n "$json" ]]; then
    if has_tool jq; then
      jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$json"
      return 0
    fi
  fi

  compose_cfg_yaml | awk -v s="$svc" '
    $1=="services:" {in_services=1; next}
    in_services && $0 ~ ("^  " s ":$") {in_svc=1; next}
    in_svc && $0 ~ /^  [A-Za-z0-9_.-]+:$/ {exit 0}
    in_svc && $0 ~ /^    image:/ {
      sub(/^    image:[[:space:]]*/, "", $0)
      print $0
      exit 0
    }
  '
}

###############################################################################
# 6. STACK COMMANDS (CLI)
###############################################################################

# One-time migration from the historical fixed 172.28/29/30 /24 networks.
# Only known LocalDevStack-owned networks are touched, and named volumes are
# never removed. New networks carry com.infocyph.network-schema=dynamic-v1.
declare -a __LDS_LEGACY_NETWORK_NAMES=(Frontend Backend DataStore)

legacy_network_expected_subnet() {
  case "${1:-}" in
  Frontend) printf '%s' '172.28.0.0/24' ;;
  Backend) printf '%s' '172.29.0.0/24' ;;
  DataStore) printf '%s' '172.30.0.0/24' ;;
  *) return 1 ;;
  esac
}

migrate_legacy_networks() {
  local network expected subnets stack_label project_label schema_label ctr ctr_project attachments project
  local -a legacy=()
  project="$(lds_project)"

  for network in "${__LDS_LEGACY_NETWORK_NAMES[@]}"; do
    docker network inspect "$network" >/dev/null 2>&1 || continue

    schema_label="$(docker network inspect -f '{{index .Labels "com.infocyph.network-schema"}}' "$network" 2>/dev/null || true)"
    [[ "$schema_label" != "dynamic-v1" ]] || continue

    expected="$(legacy_network_expected_subnet "$network")"
    subnets="$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$network" 2>/dev/null || true)"
    grep -Fxq "$expected" <<<"$subnets" || continue

    stack_label="$(docker network inspect -f '{{index .Labels "com.infocyph.stack"}}' "$network" 2>/dev/null || true)"
    project_label="$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$network" 2>/dev/null || true)"
    if [[ "$stack_label" != "LocalDevStack" || "$project_label" != "$project" ]]; then
      die "Legacy subnet detected on '$network', but ownership labels do not prove it belongs to LocalDevStack project '$project'. Remove or rename that network manually."
    fi

    while IFS= read -r ctr; do
      [[ -n "$ctr" ]] || continue
      ctr_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$ctr" 2>/dev/null || true)"
      if [[ "$ctr_project" != "$project" ]]; then
        die "Refusing to migrate '$network': container '$ctr' is not owned by LocalDevStack project '$project'."
      fi
    done < <(docker network inspect -f '{{range .Containers}}{{println .Name}}{{end}}' "$network" 2>/dev/null || true)

    legacy+=("$network")
  done

  (("${#legacy[@]}" > 0)) || return 0

  warn "Legacy fixed LocalDevStack network(s) detected: ${legacy[*]}"
  warn "Recreating stack networks dynamically; named volumes and persisted data are preserved."

  # Stop/remove only LocalDevStack Compose containers and networks. Never use -v.
  docker_compose down --remove-orphans

  for network in "${legacy[@]}"; do
    docker network inspect "$network" >/dev/null 2>&1 || continue
    attachments="$(docker network inspect -f '{{range .Containers}}{{println .Name}}{{end}}' "$network" 2>/dev/null || true)"
    [[ -z "$attachments" ]] ||
      die "Cannot remove legacy network '$network': attached container(s) remain: $(tr '\n' ' ' <<<"$attachments")"
    docker network rm "$network" >/dev/null
  done

  ok "Legacy fixed networks removed; Compose will recreate dynamic bridge networks."
}

cmd_vpn_fix() {
  warn "vpn-fix is deprecated: LocalDevStack no longer owns fixed Docker subnets."
  warn "If a VPN conflict remains after dynamic-network migration, diagnose the VPN/Docker route directly."
}

cmd_up() {
  migrate_legacy_networks
  dc_up "$@"
}

cmd_start() {
  migrate_legacy_networks
  dc_up -d "$@"
  http_reload
}

cmd_stop() { docker_compose down; }

cmd_down() {
  # Safety rails:
  #   lds down --volumes requires --yes
  local yes=0 vols=0
  local -a args=()
  while [[ "${1:-}" ]]; do
    case "$1" in
    --yes | -y)
      yes=1
      shift
      ;;
    --volumes | -v)
      vols=1
      args+=("--volumes")
      shift
      ;;
    --remove-orphans)
      args+=("--remove-orphans")
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
    esac
  done
  if ((vols)) && ((yes == 0)); then
    die "Refusing: down --volumes requires --yes"
  fi
  docker_compose down "${args[@]}"
}

cmd_restart() {
  if (($# == 0)); then
    cmd_stop
    cmd_start
    return 0
  fi

  local arg svc
  local -a services=()
  for arg in "$@"; do
    svc="$(resolve_service "$arg")"
    compose_service_exists "$svc" || die "Unknown service: $arg"
    services+=("$svc")
  done

  docker_compose restart "${services[@]}"
}
cmd_reboot() { cmd_restart; }

# ─────────────────────────────────────────────────────────────────────────────
# 6a. STATUS / PS / STATS
# ─────────────────────────────────────────────────────────────────────────────
cmd_ps() {
  if (($#)); then
    docker_compose ps "$@"
  else
    docker_compose ps
  fi
}

cmd_status() {
  local ctr project
  project="$(lds_project)"
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container not found or not running for project: $project"

  local -a flags=()
  [[ -t 1 ]] && flags+=(-t)
  docker exec "${flags[@]}" "$ctr" status "$@"
}
# ─────────────────────────────────────────────────────────────────────────────
# 6b. LOGS / OPEN
# ─────────────────────────────────────────────────────────────────────────────
cmd_logs() {
  local svc="" follow=0 since="" grep_pat=""
  while [[ "${1:-}" ]]; do
    case "$1" in
    -f | --follow)
      follow=1
      shift
      ;;
    --since)
      since="${2:-}"
      shift 2
      ;;
    --grep)
      grep_pat="${2:-}"
      shift 2
      ;;
    *)
      svc="${1:-}"
      shift
      ;;
    esac
  done

  local -a args=()
  ((follow)) && args+=("-f")
  [[ -n "$since" ]] && args+=("--since" "$since")

  if [[ -n "$svc" ]]; then
    local s
    s="$(resolve_service "$svc" || true)"
    [[ -n "$s" ]] || die "Unknown service: $svc"
    if [[ -n "$grep_pat" ]]; then
      docker_compose logs "${args[@]}" "$s" 2>&1 | text_grep "$grep_pat"
    else
      docker_compose logs "${args[@]}" "$s"
    fi
  else
    if [[ -n "$grep_pat" ]]; then
      docker_compose logs "${args[@]}" 2>&1 | text_grep "$grep_pat"
    else
      docker_compose logs "${args[@]}"
    fi
  fi
}

_enabled_profiles_csv() {
  compose_control_value COMPOSE_PROFILES ""
}

profile_enabled() {
  local wanted="${1:-}" csv p
  [[ -n "$wanted" ]] || return 1
  csv="$(_enabled_profiles_csv)"
  IFS=',' read -r -a __lds_profiles <<<"$csv"
  for p in "${__lds_profiles[@]}"; do
    p="${p//[[:space:]]/}"
    [[ "$p" == "$wanted" ]] && return 0
  done
  return 1
}

cmd_urls() {
  local -A seen=()
  local url key profile

  _print_url() {
    local value="${1:-}"
    [[ -n "$value" ]] || return 0
    [[ -z "${seen[$value]:-}" ]] || return 0
    seen["$value"]=1
    printf '%s\n' "$value"
  }

  _print_url "https://admin.localhost"
  _print_url "https://webmail.localhost"

  for key in "${SERVICE_ORDER[@]}"; do
    profile="${SERVICES[$key]:-}"
    url="${SERVICE_URL[$key]:-}"
    [[ -n "$profile" && -n "$url" ]] || continue
    profile_enabled "$profile" || continue
    _print_url "$url"
  done
}

cmd_open() {
  local target="${1:-}"
  [[ -n "$target" ]] || die "open <admin|mail|db|redis|mongo|kibana|ai|domain>"
  local url=""
  case "${target,,}" in
  http://* | https://*) url="$target" ;;
  admin | tools) url="https://admin.localhost" ;;
  mail | mailpit | webmail) url="https://webmail.localhost" ;;
  db | cloudbeaver) url="https://db.localhost" ;;
  redis | redisinsight | redis-insight | rds) url="https://ri.localhost" ;;
  mongo | me | mongoexpress | mongo-express) url="https://me.localhost" ;;
  kibana | kbn) url="https://kibana.localhost" ;;
  ai | llm) url="https://llm.localhost" ;;
  llm-ollama | ollama) url="https://llm-ollama.localhost" ;;
  llm-fastflow | fastflow) url="https://llm-fastflow.localhost" ;;
  *)
    url="https://${target}"
    ;;
  esac
  open_url "$url"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6c. PROFILES
# ─────────────────────────────────────────────────────────────────────────────
_known_profile() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1

  # Prefer compose-config JSON for exact profile membership.
  local json
  json="$(compose_cfg_json)"
  if [[ -n "$json" ]] && has_tool jq; then
    printf '%s' "$json" | jq -e --arg p "$p" '
      [ .services[]? | (.profiles // [])[] ] | index($p) != null
    ' >/dev/null 2>&1
    return $?
  fi

  # Fallback: text scan when jq/json path is unavailable.
  local f
  for f in "$COMPOSE_FILE" "${__EXTRA_FILES[@]:-}"; do
    [[ -r "$f" ]] || continue
    grep -Fq -- "$p" "$f" && return 0
  done
  return 1
}

cmd_profiles() {
  local action="${1:-list}"
  shift || true
  case "${action,,}" in
  list | "")
    local cur=""
    [[ -r "$ENV_DOCKER" ]] && cur="$(grep -E '^COMPOSE_PROFILES=' "$ENV_DOCKER" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
    printf "%bEnabled profiles:%b %s
" "$CYAN" "$NC" "${cur:-<none>}"
    printf "%bAvailable profiles:%b
" "$CYAN" "$NC"
    local available
    available="$(docker_compose config --profiles 2>/dev/null || true)"
    if [[ -n "$available" ]]; then
      printf '%s\n' "$available" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -fu | sed 's/^/  - /'
    else
      printf '  %b<none>%b\n' "$DIM" "$NC"
    fi
    # warn if enabled profile has no mention in compose
    if [[ -n "$cur" ]]; then
      local p
      IFS=',' read -r -a __ps <<<"$cur"
      for p in "${__ps[@]}"; do
        p="${p//[[:space:]]/}"
        [[ -n "$p" ]] || continue
        _known_profile "$p" || printf "%b[warn]%b enabled profile '%s' has no matching services in compose
" "$YELLOW" "$NC" "$p"
      done
    fi
    ;;
  add)
    [[ $# -gt 0 ]] || die "profiles add <profile...>"
    local p
    for p in "$@"; do
      _known_profile "$p" || die "Unknown profile: $p"
      modify_profiles add "$p"
    done
    ;;
  remove | rm | del)
    [[ $# -gt 0 ]] || die "profiles remove <profile...>"
    modify_profiles remove "$@"
    ;;
  *)
    die "profiles <list|add|remove>"
    ;;
  esac
}


# ─────────────────────────────────────────────────────────────────────────────
# 6e. SECRETS / CERT / HOST / UI
# ─────────────────────────────────────────────────────────────────────────────
cmd_secrets() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || {
    err "server-tools container is not running for project: $(lds_project)"
    return 69
  }
  docker exec -it "$ctr" senv "$@"
}

cmd_cert() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  docker exec -it "$ctr" certify "$@"
}

cmd_host() {
  local sub="${1:-}"
  shift || true
  case "${sub,,}" in
  add)
    setup_domain
    ;;
  rm | remove | del | delete)
    delete_domain "$@"
    ;;
  list)
    local ctr
    ctr="$(_project_tools_container_running || true)"
    [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
    docker exec "$ctr" sh -lc '
      for f in /etc/share/vhosts/nginx/*.conf; do
        [ -e "$f" ] || continue
        basename "$f" .conf
      done
    ' | LC_ALL=C sort
    ;;
  *)
    die "host <add|rm|list>"
    ;;
  esac
}

cmd_ui() {
  _shell_context_reset
  _shell_resolve_tools || return $?
  _shell_context_exec_interactive lazydocker
}

# ─────────────────────────────────────────────────────────────────────────────
# 6f. EXEC / EVENTS / CLEAN / DISK
# ─────────────────────────────────────────────────────────────────────────────
cmd_exec() {
  local requested="${1:-}"
  shift || true
  [[ -n "$requested" ]] || {
    err "Usage: lds stack exec <service> [--] [command...]"
    return 64
  }
  [[ "${1:-}" == -- ]] && shift

  local service
  service="$(resolve_service "$requested" || true)"
  if [[ -z "$service" ]] || ! compose_service_exists "$service"; then
    err "Current-project service not found: $requested"
    return 66
  fi

  _shell_context_reset
  _shell_resolve_service "$service" || return $?

  if (($# > 0)); then
    _shell_context_exec_argv "$@"
  else
    _shell_context_open
  fi
}

cmd_events() {
  local since="${1:-1h}"
  local project
  project="$(lds_project)"
  docker events --since "$since" --filter "label=com.docker.compose.project=$project"
}

cmd_clean() {
  local yes=0 vols=0 global=0
  while [[ "${1:-}" ]]; do
    case "$1" in
    --yes | -y)
      yes=1
      shift
      ;;
    --volumes | -v)
      vols=1
      shift
      ;;
    --global)
      global=1
      shift
      ;;
    *)
      die "clean [--yes|-y] [--volumes|-v] [--global]"
      ;;
    esac
  done

  ((yes)) || die "clean requires --yes"

  if ((global)); then
    warn "Global Docker cleanup requested; unrelated stopped containers, images, networks, build cache, and optionally volumes may be removed."

    printf "%b[clean]%b globally pruning stopped containers...\n" "$CYAN" "$NC"
    docker container prune -f >/dev/null 2>&1 || true
    printf "%b[clean]%b globally pruning unused networks...\n" "$CYAN" "$NC"
    docker network prune -f >/dev/null 2>&1 || true
    printf "%b[clean]%b globally pruning unused images...\n" "$CYAN" "$NC"
    docker image prune -a -f >/dev/null 2>&1 || true
    printf "%b[clean]%b globally pruning build cache...\n" "$CYAN" "$NC"
    docker builder prune -a -f >/dev/null 2>&1 || true
    if ((vols)); then
      printf "%b[clean]%b globally pruning unused volumes...\n" "$CYAN" "$NC"
      docker volume prune -f >/dev/null 2>&1 || true
    fi
    printf "%b[clean]%b global cleanup done\n" "$GREEN" "$NC"
    return 0
  fi

  local project id net refs image
  local -a ids=() networks=() volumes=() images=()
  project="$(lds_project)"

  mapfile -t ids < <(
    {
      docker ps -aq --filter "label=com.docker.compose.project=$project" --filter status=created
      docker ps -aq --filter "label=com.docker.compose.project=$project" --filter status=exited
      docker ps -aq --filter "label=com.docker.compose.project=$project" --filter status=dead
    } 2>/dev/null | awk 'NF' | sort -u
  )
  if (("${#ids[@]}" > 0)); then
    printf "%b[clean]%b removing stopped LocalDevStack containers...\n" "$CYAN" "$NC"
    docker rm "${ids[@]}" >/dev/null 2>&1 || true
  fi

  mapfile -t networks < <(
    docker network ls -q       --filter "label=com.infocyph.stack=LocalDevStack"       --filter "label=com.docker.compose.project=$project" 2>/dev/null || true
  )
  for net in "${networks[@]}"; do
    [[ -n "$net" ]] || continue
    refs="$(docker network inspect -f '{{len .Containers}}' "$net" 2>/dev/null || printf '1')"
    [[ "$refs" == "0" ]] || continue
    docker network rm "$net" >/dev/null 2>&1 || true
  done

  mapfile -t images < <(
    {
      docker images -q --filter 'reference=localdevstack-php:*'
      docker images -q --filter 'reference=localdevstack-node:*'
    } 2>/dev/null | awk 'NF' | sort -u
  )
  for image in "${images[@]}"; do
    docker image rm "$image" >/dev/null 2>&1 || true
  done

  if ((vols)); then
    mapfile -t volumes < <(
      docker volume ls -q         --filter "label=com.infocyph.lds=1"         --filter "label=com.infocyph.stack=LocalDevStack" 2>/dev/null || true
    )
    for id in "${volumes[@]}"; do
      [[ -n "$id" ]] || continue
      docker volume rm "$id" >/dev/null 2>&1 || true
    done
  fi

  printf "%b[clean]%b LocalDevStack-scoped cleanup done\n" "$GREEN" "$NC"
  warn "Docker build cache is intentionally untouched by scoped cleanup; use --global for host-wide pruning."
}


normalize_service() {
  local raw="${1:-}"
  local s="${raw//[[:space:]]/}"
  [[ -n "$s" ]] || {
    printf '%s' ""
    return 0
  }

  local low="${s,,}"

  local key="${low//_/}"
  key="${key//-/}"
  if [[ "$key" =~ ^php ]]; then
    local ver="${key#php}"
    ver="${ver//[^0-9]/}"
    if [[ "$ver" =~ ^([0-9])([0-9]).* ]]; then
      printf 'php%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      return 0
    fi
    printf 'php'
    return 0
  fi

  low="${low//_/-}"
  while [[ "$low" == *"--"* ]]; do low="${low//--/-}"; done
  printf '%s' "$low"
}

cmd_rebuild() {
  local -a targets=() all_svcs=()
  local arg svc img
  declare -A seen=()

  # -----------------------------
  # helper: add a service once
  # -----------------------------
  _add_target() {
    local s="$1"
    [[ -n "$s" ]] || return 0
    [[ -n "${seen[$s]:-}" ]] && return 0
    seen[$s]=1
    targets+=("$s")
  }

  # -----------------------------
  # helper: trim
  # -----------------------------
  _trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
  }

  # -----------------------------
  # helper: interactive selection (comma separated, supports ranges)
  # accepts: "all" or "1,3,5-7" or mix with names "nginx,2,5-6"
  # -----------------------------
  _pick_targets_interactive() {
    compose_services_load
    all_svcs=("${__COMPOSE_SVCS[@]}")
    if ((${#all_svcs[@]})); then
      mapfile -t all_svcs < <(printf '%s\n' "${all_svcs[@]}" | LC_ALL=C sort -f -u)
    fi
    [[ ${#all_svcs[@]} -gt 0 ]] || die "No services found (docker compose config --services failed?)"

    echo
    echo "Select services to rebuild (comma separated; ranges allowed)."
    echo "Examples: 1,3,5-7   |   nginx,2,5-6   |   all"
    echo

    local i
    for i in "${!all_svcs[@]}"; do
      printf "  %2d) %s\n" "$((i + 1))" "${all_svcs[$i]}"
    done

    echo
    local sel
    read -r -p "Pick: " sel
    sel="$(_trim "${sel:-}")"
    [[ -n "$sel" ]] || die "No selection provided."

    if [[ "${sel,,}" == "all" ]]; then
      for svc in "${all_svcs[@]}"; do _add_target "$svc"; done
      return 0
    fi

    # split by comma
    local IFS=,
    for arg in $sel; do
      arg="$(_trim "$arg")"
      [[ -n "$arg" ]] || continue

      # range like 3-7
      if [[ "$arg" =~ ^[0-9]+-[0-9]+$ ]]; then
        local a b
        a="${arg%-*}"
        b="${arg#*-}"
        ((a >= 1)) || continue
        ((b >= 1)) || continue
        ((a <= b)) || {
          local t="$a"
          a="$b"
          b="$t"
        }

        local n
        for ((n = a; n <= b; n++)); do
          ((n >= 1 && n <= ${#all_svcs[@]})) || continue
          _add_target "${all_svcs[$((n - 1))]}"
        done
        continue
      fi

      # single index
      if [[ "$arg" =~ ^[0-9]+$ ]]; then
        local n="$arg"
        ((n >= 1 && n <= ${#all_svcs[@]})) || continue
        _add_target "${all_svcs[$((n - 1))]}"
        continue
      fi

      # treat as service/container name
      svc="$(resolve_service "$arg")"
      [[ -n "$svc" ]] && _add_target "$svc"
    done

    [[ ${#targets[@]} -gt 0 ]] || die "No valid services selected."
  }

  # -----------------------------
  # build target list
  # -----------------------------
  if (($# == 0)); then
    _pick_targets_interactive
  elif [[ "${1,,}" == "all" ]]; then
    compose_services_load
    targets=("${__COMPOSE_SVCS[@]}")
    [[ ${#targets[@]} -gt 0 ]] || die "No services found (docker compose config --services failed?)"
  else
    for arg in "$@"; do
      svc="$(resolve_service "$arg")"
      [[ -n "$svc" ]] || continue
      _add_target "$svc"
    done
    [[ ${#targets[@]} -gt 0 ]] || die "No valid services provided."
  fi

  # -----------------------------
  # rebuild each target
  # -----------------------------
  for svc in "${targets[@]}"; do
    [[ -n "$svc" ]] || continue
    compose_service_exists "$svc" || die "Unknown service/container: '$svc'"

    if compose_has_build "$svc"; then
      logq rebuild "build/recreate $svc"
      dc_build --pull "$svc"
      dc_up -d --no-deps --force-recreate "$svc"
      continue
    fi

    img="$(compose_image_for_service "$svc")"
    logq rebuild "pull/recreate $svc${img:+ ($img)}"

    docker_compose rm -sf "$svc" >/dev/null 2>&1 || true

    if [[ -n "${img:-}" ]]; then
      docker rmi -f "$img" >/dev/null 2>&1 || true
      dc_pull "$svc" || true
    else
      dc_build --pull "$svc" >/dev/null 2>&1 || true
    fi

    dc_up -d --no-deps --force-recreate "$svc"
  done
  logq reboot "Rebooting stacks"
  cmd_reboot
}


cmd_tools() {
  local sub="${1:-sh}"
  shift || true

  _shell_context_reset
  _shell_resolve_tools || return $?

  case "${sub,,}" in
  sh | shell | "")
    _shell_context_open
    ;;
  exec)
    [[ "${1:-}" == -- ]] && shift
    (($# > 0)) || {
      err "Usage: lds tools exec [--] <command> [args...]"
      return 64
    }
    _shell_context_exec_argv "$@"
    ;;
  shell-exec)
    (($# == 1)) || {
      err "Usage: lds tools shell-exec <shell-expression>"
      return 64
    }
    _shell_context_exec_expression "$1"
    ;;
  file)
    local path="${1:-}"
    [[ -n "$path" ]] || {
      err "Usage: lds tools file <path>"
      return 64
    }
    _shell_context_exec_argv sh -lc '
      ls -la -- "$1" 2>/dev/null || true
      printf "\n"
      sed -n "1,200p" -- "$1" 2>/dev/null || true
    ' sh "$path"
    ;;
  *)
    die "tools <sh|exec|shell-exec|file>"
    ;;
  esac
}

cmd_http() { [[ ${1:-} == reload ]] && http_reload; }
cmd_cli() {
  local target="${1:-}"
  shift || true

  [[ -n "$target" ]] || {
    err "Usage: lds cli <service|container> [--] [command...]"
    return 64
  }
  [[ "${1:-}" == -- ]] && shift

  _shell_resolve_service_or_container "$target" || return $?

  if (($# > 0)); then
    _shell_context_exec_argv "$@"
  else
    _shell_context_open
  fi
}

_CORE_DOMAIN=''
_CORE_APP=''
_CORE_CONTAINER_ID=''
_CORE_CONTAINER_NAME=''
_CORE_WORKDIR=''

_core_is_domain() {
  local target="${1:-}" domain
  [[ -n "$target" ]] || return 1

  # Domain ownership lives in Tools. Only an exact discovered domain is treated
  # as a domain here; hostname-shaped service/container names remain valid
  # execution targets instead of being guessed from their spelling.
  while IFS= read -r domain; do
    [[ "$domain" == "$target" ]] && return 0
  done < <(_core_domain_list 2>/dev/null || true)

  return 1
}

_core_domain_list() {
  local tools_ctr
  tools_ctr="$(_project_tools_container_running || true)"
  [[ -n "$tools_ctr" ]] || {
    err "server-tools container is not running for project: $(lds_project)"
    return 69
  }

  docker exec "$tools_ctr" domain-which --list-domains 2>/dev/null |
    sed '/^[[:space:]]*$/d' |
    LC_ALL=C sort -u
}

_core_choose_domain() {
  local -a domains=()
  mapfile -t domains < <(_core_domain_list) || return $?
  (("${#domains[@]}" > 0)) || {
    err "No domains found"
    return 66
  }

  if (("${#domains[@]}" == 1)); then
    printf '%s' "${domains[0]}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    printf "%b[core]%b No domain provided. Available domains:\n" "$YELLOW" "$NC" >&2
    local i=1 domain
    for domain in "${domains[@]}"; do
      printf "  %2d) %s\n" "$i" "$domain" >&2
      ((i++))
    done
    err "No TTY to prompt. Use: lds core <domain>"
    return 64
  fi

  printf "%bSelect domain:%b\n" "$CYAN" "$NC" >&2
  local i=1 domain
  for domain in "${domains[@]}"; do
    printf "  %b%2d)%b %s\n" "$CYAN" "$i" "$NC" "$domain" >&2
    ((i++))
  done

  local answer=''
  while true; do
    read -r -p "Enter number (1-${#domains[@]}): " answer
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    [[ "$answer" =~ ^[0-9]+$ ]] || {
      printf "%bInvalid input.%b\n" "$YELLOW" "$NC" >&2
      continue
    }
    ((answer >= 1 && answer <= ${#domains[@]})) || {
      printf "%bOut of range.%b\n" "$YELLOW" "$NC" >&2
      continue
    }
    printf '%s' "${domains[$((answer - 1))]}"
    return 0
  done
}

_core_domain_resolve() {
  local domain="${1:-}" tools_ctr app target docroot preferred

  _CORE_DOMAIN=''
  _CORE_APP=''
  _CORE_CONTAINER_ID=''
  _CORE_CONTAINER_NAME=''
  _CORE_WORKDIR=''

  [[ -n "$domain" ]] || {
    err "Core domain is required"
    return 64
  }

  tools_ctr="$(_project_tools_container_running || true)"
  [[ -n "$tools_ctr" ]] || {
    err "server-tools container is not running for project: $(lds_project)"
    return 69
  }

  app="$(docker exec "$tools_ctr" domain-which --app --quiet "$domain" 2>/dev/null)" || {
    err "Unknown domain: $domain"
    return 66
  }
  target="$(docker exec "$tools_ctr" domain-which --container --quiet "$domain" 2>/dev/null)" || {
    err "No container resolved for: $domain"
    return 66
  }
  docroot="$(docker exec "$tools_ctr" domain-which --docroot --quiet "$domain" 2>/dev/null || true)"
  [[ -n "$target" ]] || {
    err "No container resolved for: $domain"
    return 66
  }

  _container_resolve_target "$target" || return $?
  _container_require_running "$_CONTAINER_TARGET_ID" || return $?

  if [[ "${app,,}" == node ]]; then
    preferred=/app
  else
    preferred="${docroot:-/app}"
  fi

  _CORE_DOMAIN="$domain"
  _CORE_APP="$app"
  _CORE_CONTAINER_ID="$_CONTAINER_TARGET_ID"
  _CORE_CONTAINER_NAME="$_CONTAINER_TARGET_NAME"
  _CORE_WORKDIR="$(_container_first_existing_dir "$_CORE_CONTAINER_ID" "$preferred" /app /)" || return $?
}

_SHELL_TARGET_KIND=''
_SHELL_TARGET_REQUESTED=''
_SHELL_DOMAIN=''
_SHELL_APP=''
_SHELL_SERVICE=''
_SHELL_CONTAINER_ID=''
_SHELL_CONTAINER_NAME=''
_SHELL_WORKDIR=''

_shell_context_reset() {
  _SHELL_TARGET_KIND=''
  _SHELL_TARGET_REQUESTED=''
  _SHELL_DOMAIN=''
  _SHELL_APP=''
  _SHELL_SERVICE=''
  _SHELL_CONTAINER_ID=''
  _SHELL_CONTAINER_NAME=''
  _SHELL_WORKDIR=''
}

_shell_context_from_resolved_container() {
  local kind="${1:-container}" requested="${2:-}"
  _SHELL_TARGET_KIND="$kind"
  _SHELL_TARGET_REQUESTED="$requested"
  _SHELL_SERVICE="$_CONTAINER_TARGET_SERVICE"
  _SHELL_CONTAINER_ID="$_CONTAINER_TARGET_ID"
  _SHELL_CONTAINER_NAME="$_CONTAINER_TARGET_NAME"
}

_shell_resolve_domain() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || {
    err "Shell domain target is required"
    return 64
  }
  _core_is_domain "$domain" || {
    err "Domain not found: $domain"
    return 66
  }
  _core_domain_resolve "$domain" || return $?

  _SHELL_TARGET_KIND=domain
  _SHELL_TARGET_REQUESTED="$domain"
  _SHELL_DOMAIN="$_CORE_DOMAIN"
  _SHELL_APP="$_CORE_APP"
  _SHELL_SERVICE="$_CONTAINER_TARGET_SERVICE"
  _SHELL_CONTAINER_ID="$_CORE_CONTAINER_ID"
  _SHELL_CONTAINER_NAME="$_CORE_CONTAINER_NAME"
  _SHELL_WORKDIR="$_CORE_WORKDIR"
}

_shell_resolve_tools() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || {
    err "server-tools container is not running for project: $(lds_project)"
    return 69
  }
  _container_require_running "$ctr" || return $?

  _SHELL_TARGET_KIND=tools
  _SHELL_TARGET_REQUESTED=tools
  _SHELL_SERVICE=server-tools
  _SHELL_CONTAINER_ID="$ctr"
  _SHELL_CONTAINER_NAME="$ctr"
}

_shell_resolve_service() {
  local service="${1:-}"
  [[ -n "$service" ]] || {
    err "Shell service target is required"
    return 64
  }
  _container_project_service_exists "$service" || {
    err "Current-project service not found: $service"
    return 66
  }
  _container_resolve_target "$service" || return $?
  _shell_context_from_resolved_container service "$service"
}

_shell_exact_container_exists() {
  local target="${1:-}" running
  [[ -n "$target" ]] || return 1
  running="$(_container_docker inspect -f '{{.State.Running}}' "$target" 2>/dev/null || true)"
  [[ "$running" == true || "$running" == false ]]
}

_shell_resolve_container() {
  local target="${1:-}" id name service
  [[ -n "$target" ]] || {
    err "Shell container target is required"
    return 64
  }
  _shell_exact_container_exists "$target" || {
    err "Container not found: $target"
    return 66
  }

  id="$(_container_docker inspect -f '{{.Id}}' "$target" 2>/dev/null || true)"
  [[ -n "$id" ]] || {
    err "Container not found: $target"
    return 66
  }
  name="$(_container_name_from_id "$id" || true)"
  [[ -n "$name" ]] || name="$target"
  service="$(_container_docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null || true)"

  _SHELL_TARGET_KIND=container
  _SHELL_TARGET_REQUESTED="$target"
  _SHELL_SERVICE="$service"
  _SHELL_CONTAINER_ID="$id"
  _SHELL_CONTAINER_NAME="$name"
}

_shell_app_name_valid() {
  local name="${1:-}"
  [[ -n "$name" && "$name" != . && "$name" != .. && "$name" != */* ]]
}

_shell_resolve_app() {
  local name="${1:-}" ctr path
  _shell_app_name_valid "$name" || {
    err "Application directory must be a direct child name under /app: $name"
    return 64
  }

  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || {
    err "server-tools container is not running for project: $(lds_project)"
    return 69
  }
  _container_require_running "$ctr" || return $?

  path="/app/$name"
  _container_docker exec "$ctr" sh -c '[ -d "$1" ]' sh "$path" >/dev/null 2>&1 || {
    err "Application directory not found: $path"
    return 66
  }

  _SHELL_TARGET_KIND=app
  _SHELL_TARGET_REQUESTED="$name"
  _SHELL_APP="$name"
  _SHELL_SERVICE=server-tools
  _SHELL_CONTAINER_ID="$ctr"
  _SHELL_CONTAINER_NAME="$ctr"
  _SHELL_WORKDIR="$path"
}

_shell_resolve_target() {
  local requested="${1:-}" target state
  _shell_context_reset

  [[ -n "$requested" ]] || {
    err "Shell target is required"
    return 64
  }

  case "$requested" in
  domain:*)
    target="${requested#domain:}"
    _shell_resolve_domain "$target"
    return $?
    ;;
  service:*)
    target="${requested#service:}"
    _shell_resolve_service "$target"
    return $?
    ;;
  container:*)
    target="${requested#container:}"
    _shell_resolve_container "$target"
    return $?
    ;;
  app:*)
    target="${requested#app:}"
    _shell_resolve_app "$target"
    return $?
    ;;
  utility:tools)
    _shell_resolve_tools
    return $?
    ;;
  esac

  if _core_is_domain "$requested"; then
    _shell_resolve_domain "$requested"
    return $?
  fi

  if [[ "$requested" == tools ]]; then
    _shell_resolve_tools
    return $?
  fi

  if _container_project_service_exists "$requested"; then
    _shell_resolve_service "$requested"
    return $?
  fi

  state="$(_container_docker inspect -f '{{.State.Running}}' "$requested" 2>/dev/null || true)"
  if [[ "$state" == true || "$state" == false ]]; then
    _shell_resolve_container "$requested"
    return $?
  fi

  if _shell_app_name_valid "$requested"; then
    local tools_ctr
    tools_ctr="$(_project_tools_container_running || true)"
    if [[ -z "$tools_ctr" ]]; then
      err "server-tools container is not running for project: $(lds_project)"
      return 69
    fi
    if _container_docker exec "$tools_ctr" sh -c '[ -d "$1" ]' sh "/app/$requested" >/dev/null 2>&1; then
      _shell_resolve_app "$requested"
      return $?
    fi
  fi

  err "Shell target not found: $requested (checked domain, tools, service, container, and /app directory)"
  return 66
}

_shell_resolve_service_or_container() {
  local target="${1:-}"
  _shell_context_reset
  _container_resolve_target "$target" || return $?
  _shell_context_from_resolved_container "$_CONTAINER_TARGET_KIND" "$target"
}

_shell_context_open() {
  local container="$_SHELL_CONTAINER_ID" workdir="$_SHELL_WORKDIR"
  [[ -n "$container" ]] || {
    err "Shell context has no container"
    return 64
  }
  if [[ -n "$workdir" ]]; then
    _container_open_shell "$container" --workdir "$workdir"
  else
    _container_open_shell "$container"
  fi
}

_shell_context_exec_argv() {
  local container="$_SHELL_CONTAINER_ID" workdir="$_SHELL_WORKDIR"
  (($# > 0)) || {
    err "Shell context command is required"
    return 64
  }
  if [[ -n "$workdir" ]]; then
    _container_exec_argv "$container" --workdir "$workdir" -- "$@"
  else
    _container_exec_argv "$container" -- "$@"
  fi
}

_shell_context_exec_expression() {
  (($# == 1)) || {
    err "Shell expression is required"
    return 64
  }
  _shell_context_exec_argv sh -lc "$1"
}

_shell_context_exec_interactive() {
  local container="$_SHELL_CONTAINER_ID" workdir="$_SHELL_WORKDIR"
  (($# > 0)) || {
    err "Interactive shell context command is required"
    return 64
  }
  if [[ -n "$workdir" ]]; then
    _container_exec_interactive_argv "$container" --workdir "$workdir" -- "$@"
  else
    _container_exec_interactive_argv "$container" -- "$@"
  fi
}

declare -a _SHELL_MENU_KIND=()
declare -a _SHELL_MENU_NAME=()
declare -a _SHELL_MENU_SELECTOR=()

_shell_menu_reset() {
  _SHELL_MENU_KIND=()
  _SHELL_MENU_NAME=()
  _SHELL_MENU_SELECTOR=()
}

_shell_menu_add() {
  local kind="${1:-}" name="${2:-}" selector="${3:-}"
  [[ -n "$kind" && -n "$name" && -n "$selector" ]] || return 1
  _SHELL_MENU_KIND+=("$kind")
  _SHELL_MENU_NAME+=("$name")
  _SHELL_MENU_SELECTOR+=("$selector")
}

_shell_app_list() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || return 0

  _container_docker exec "$ctr" sh -c '
    for path in /app/*; do
      [ -d "$path" ] || continue
      basename "$path"
    done
  ' 2>/dev/null |
    sed '/^[[:space:]]*$/d' |
    LC_ALL=C sort -u
}

_shell_service_list() {
  docker_compose config --services 2>/dev/null |
    sed '/^[[:space:]]*$/d' |
    LC_ALL=C sort -u
}

_shell_container_list() {
  _container_docker ps --format '{{.Names}}' 2>/dev/null |
    sed '/^[[:space:]]*$/d' |
    LC_ALL=C sort -u
}

_shell_menu_build() {
  _shell_menu_reset
  local item

  while IFS= read -r item; do
    [[ -n "$item" ]] && _shell_menu_add domain "$item" "domain:$item"
  done < <(_core_domain_list 2>/dev/null || true)

  while IFS= read -r item; do
    [[ -n "$item" ]] && _shell_menu_add app "$item" "app:$item"
  done < <(_shell_app_list 2>/dev/null || true)

  while IFS= read -r item; do
    [[ -n "$item" ]] && _shell_menu_add service "$item" "service:$item"
  done < <(_shell_service_list 2>/dev/null || true)

  while IFS= read -r item; do
    [[ -n "$item" ]] && _shell_menu_add container "$item" "container:$item"
  done < <(_shell_container_list 2>/dev/null || true)

  if [[ -n "$(_project_tools_container_running || true)" ]]; then
    _shell_menu_add utility tools utility:tools
  fi
}

_shell_menu_label() {
  case "${1:-}" in
  domain) printf '%s' 'Applications / Domains' ;;
  app) printf '%s' 'Application Directories' ;;
  service) printf '%s' 'Services' ;;
  container) printf '%s' 'Containers' ;;
  utility) printf '%s' 'Utilities' ;;
  *) printf '%s' 'Other' ;;
  esac
}

_shell_menu_print() {
  local previous='' kind label i
  for ((i = 0; i < ${#_SHELL_MENU_NAME[@]}; i++)); do
    kind="${_SHELL_MENU_KIND[$i]}"
    if [[ "$kind" != "$previous" ]]; then
      label="$(_shell_menu_label "$kind")"
      [[ -z "$previous" ]] || printf '\n' >&2
      printf '%b%s%b\n' "$CYAN" "$label" "$NC" >&2
      previous="$kind"
    fi
    printf '  %2d) %s\n' "$((i + 1))" "${_SHELL_MENU_NAME[$i]}" >&2
  done
}

_shell_selector_is_tty() {
  [[ -t 0 ]]
}

_shell_menu_match_name() {
  local answer="${1:-}" i count=0 match=''
  for ((i = 0; i < ${#_SHELL_MENU_NAME[@]}; i++)); do
    if [[ "${_SHELL_MENU_NAME[$i]}" == "$answer" ]]; then
      ((count += 1))
      match="${_SHELL_MENU_SELECTOR[$i]}"
    fi
  done

  if ((count == 1)); then
    printf '%s' "$match"
    return 0
  fi
  if ((count > 1)); then
    printf '%bAmbiguous name:%b %s\n' "$YELLOW" "$NC" "$answer" >&2
    printf 'Use one of:\n' >&2
    for ((i = 0; i < ${#_SHELL_MENU_NAME[@]}; i++)); do
      [[ "${_SHELL_MENU_NAME[$i]}" == "$answer" ]] &&
        printf '  %s\n' "${_SHELL_MENU_SELECTOR[$i]}" >&2
    done
    return 65
  fi
  return 66
}

_shell_choose_target() {
  _shell_menu_build
  (("${#_SHELL_MENU_NAME[@]}" > 0)) || {
    err "No shell targets are available"
    return 66
  }

  _shell_menu_print

  if ! _shell_selector_is_tty; then
    err "No TTY to prompt. Use: lds shell <target>"
    return 64
  fi

  local answer='' i selector rc
  while true; do
    read -r -p "Enter number or name: " answer
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"

    if [[ "$answer" =~ ^[0-9]+$ ]]; then
      if ((answer >= 1 && answer <= ${#_SHELL_MENU_SELECTOR[@]})); then
        printf '%s' "${_SHELL_MENU_SELECTOR[$((answer - 1))]}"
        return 0
      fi
      printf '%bOut of range.%b\n' "$YELLOW" "$NC" >&2
      continue
    fi

    for ((i = 0; i < ${#_SHELL_MENU_SELECTOR[@]}; i++)); do
      if [[ "${_SHELL_MENU_SELECTOR[$i]}" == "$answer" ]]; then
        printf '%s' "$answer"
        return 0
      fi
    done

    if selector="$(_shell_menu_match_name "$answer")"; then
      printf '%s' "$selector"
      return 0
    else
      rc=$?
    fi
    ((rc == 65)) && continue

    printf '%bUnknown target.%b %s\n' "$YELLOW" "$NC" "$answer" >&2
  done
}

cmd_shell() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    target="$(_shell_choose_target)" || return $?
  else
    shift || true
  fi

  _shell_resolve_target "$target" || return $?

  if (($# == 0)); then
    _shell_context_open
    return $?
  fi

  case "${1:-}" in
  --)
    shift
    (($# > 0)) || {
      err "Usage: lds shell <target> -- <command> [args...]"
      return 64
    }
    _shell_context_exec_argv "$@"
    ;;
  --shell)
    shift
    (($# == 1)) || {
      err "Usage: lds shell <target> --shell <shell-expression>"
      return 64
    }
    _shell_context_exec_expression "$1"
    ;;
  --interactive | -i)
    shift
    (($# > 0)) || {
      err "Usage: lds shell <target> --interactive <command> [args...]"
      return 64
    }
    _shell_context_exec_interactive "$@"
    ;;
  *)
    _shell_context_exec_argv "$@"
    ;;
  esac
}

cmd_core() {
  local target="${1:-}"
  [[ -n "$target" ]] && shift || true

  if [[ -z "$target" ]]; then
    target="$(_core_choose_domain)" || return $?
  fi

  [[ "${1:-}" == -- ]] && shift

  if _core_is_domain "$target"; then
    _shell_context_reset
    _shell_resolve_domain "$target" || return $?
  else
    _shell_resolve_service_or_container "$target" || return $?
  fi

  if (($# > 0)); then
    _shell_context_exec_argv "$@"
  else
    _shell_context_open
  fi
}

cmd_setup() {
  add_required_env
  case ${1:-} in
  init) env_init ;;
  permission | permissions | perms | perm) fix_perms ;;
  domain) setup_domain ;;
  profiles | profile) process_all ;;
  *) die "setup <init|permissions|domain|profiles>" ;;
  esac
}

cmd_certificate() {
  case ${1:-} in
  install)
    shift || true
    install_ca
    ;;
  uninstall | remove | rm)
    shift || true
    uninstall_ca "${@:-}"
    ;;
  *)
    die "certificate <install|uninstall [--all]>"
    ;;
  esac
}

###############################################################################
# NOTIFY
###############################################################################
notify_watch() {
  local container="${1:-}"
  if [[ -z "$container" ]]; then
    container="$(_project_tools_container_running || true)"
    [[ -n "$container" ]] || die "server-tools container is not running for project: $(lds_project)"
  fi
  local prefix="__HOST_NOTIFY__"

  need docker

  local _disp="${DISPLAY-}"
  local _dbus="${DBUS_SESSION_BUS_ADDRESS-}"

  # Args: timeout(ms) urgency title body
  _host_notify() {
    local timeout="${1:-2500}" urgency="${2:-normal}" title="${3:-Notification}" body="${4:-}"

    # Linux desktop (or WSLg)
    if has_cmd notify-send; then
      (env DISPLAY="${_disp-}" DBUS_SESSION_BUS_ADDRESS="${_dbus-}" \
        setsid -f notify-send -u "$urgency" -t "$timeout" "$title" "$body" \
        >/dev/null 2>&1 || true) &
      return 0
    fi

    # Windows toast (Git Bash) / WSL-on-Windows
    if has_cmd powershell.exe; then
      # Pass values as args to avoid quoting issues entirely.
      # Note: urgency/timeout not used by toast api here; kept for parity.
      powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
        'param([string]$t,[string]$b)
          try {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null

            function Esc([string]$s) {
              if ($null -eq $s) { return "" }
              return ($s -replace "&","&amp;" -replace "<","&lt;" -replace ">","&gt;" -replace "\"","&quot;" -replace "'\''","&apos;")
            }

            $title = Esc $t
            $body  = Esc $b

            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$title</text><text>$body</text></binding></visual></toast>")
            $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Devtainer").Show($toast)
          } catch { }' \
        --% "$title" "$body" >/dev/null 2>&1 || true

      return 0
    fi

    # Fallback
    printf "%s [%s] %s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$urgency" "$title" "$body" >&2
    return 0
  }

  trap - ERR
  set +e
  set +o pipefail

  local _stop=0

  _watcher_notify() {
    local urgency="${1:-critical}" title="${2:-Notifier}" body="${3:-Watcher event}"
    _host_notify 2500 "$urgency" "$title" "$body"
  }

  _watcher_int_term() {
    _stop=1
    _watcher_notify critical "Notifier" "Notification watcher interrupted/exiting"
    printf "%b[watcher]%b Notification watcher interrupted/exiting\n" "$RED" "$NC" >&2
  }
  trap _watcher_int_term INT TERM

  local grep_cmd=(grep -a --line-buffered -E "^${prefix}([[:space:]]|$)")
  has_cmd stdbuf && grep_cmd=(stdbuf -oL -eL "${grep_cmd[@]}")

  printf "%bNotify Watch:%b monitoring is active. Ctrl+C to stop.\n" "$GREEN" "$NC"

  while ((_stop == 0)); do
    if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
      _watcher_notify critical "Notifier" "Watcher stopped: $container is not running"
      printf "%b[watcher]%b %s is not running; exiting.\n" "$RED" "$NC" "$container" >&2
      break
    fi

    docker logs -f --tail 0 "$container" 2>&1 |
      ("${grep_cmd[@]}" || true) |
      while IFS=$'\t' read -r _ f1 f2 f3 f4 rest; do
        local timeout urgency title body

        if [[ "${f1:-}" =~ ^[0-9]{1,6}$ ]]; then
          timeout="$f1"
          urgency="${f2:-normal}"
          title="${f3:-Notification}"
          body="${f4:-}"
        else
          timeout="2500"
          urgency="${f1:-normal}"
          title="${f2:-Notification}"
          body="${f3:-}"
        fi

        [[ -n "${rest:-}" ]] && body+=$'\t'"${rest}"
        case "$urgency" in low | normal | critical) ;; *) urgency="normal" ;; esac

        _host_notify "$timeout" "$urgency" "$title" "$body"
        printf "%s [%s] %s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$urgency" "$title" "$body" >&2
      done

    ((_stop)) && break

    if docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
      _watcher_notify critical "Notifier" "Watcher lost log stream (docker logs ended). Reconnecting…"
      printf "%b[watcher]%b docker logs ended; reconnecting...\n" "$YELLOW" "$NC" >&2
      sleep 1
      continue
    fi

    _watcher_notify critical "Notifier" "Watcher stopped: $container stopped"
    printf "%b[watcher]%b %s stopped; exiting.\n" "$RED" "$NC" "$container" >&2
    break
  done

  trap - INT TERM
  set -euo pipefail

  ((_stop)) && return 130
  return 0
}

notify_test() {
  local title="${1:-Notifier OK}"
  local body="${2:-Hello from host via project server-tools container}"
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  docker exec "$ctr" notify -t 2500 -u normal "$title" "$body"
}

cmd_notify() {
  case ${1:-watch} in
  watch) notify_watch "${2:-}" ;;
  test) notify_test "${2:-Notifier OK}" "${3:-Hello from host}" ;;
  *) die "notify <watch [container]|test \"Title\" \"Body\">" ;;
  esac
}

open_url() {
  local url="${1:-}"
  [[ -n "$url" ]] || return 0

  # WSL/Windows helpers first when available
  if grep -qi microsoft /proc/version 2>/dev/null; then
    if has_cmd powershell.exe; then
      powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 || true
      return 0
    fi
    if has_cmd cmd.exe; then
      cmd.exe /c start "" "$url" >/dev/null 2>&1 || true
      return 0
    fi
  fi

  if has_cmd xdg-open; then
    (xdg-open "$url" >/dev/null 2>&1 &)
    return 0
  fi
  if has_cmd open; then
    (open "$url" >/dev/null 2>&1 &)
    return 0
  fi
  if has_cmd powershell; then
    (powershell -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 &)
    return 0
  fi

  printf "%bINFO%b: open this URL manually → %s\n" "$YELLOW" "$NC" "$url"
}

