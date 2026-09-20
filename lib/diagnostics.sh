# shellcheck shell=bash
_shq() { printf '%q' "$1"; }

cmd_diag() {
  local sub="${1:-}"
  shift || true

  case "${sub,,}" in
  dns)
    local dom="${1:-}"
    [[ -n "$dom" ]] || die "diag dns <domain>"
    local qdom
    qdom="$(_shq "$dom")"
    _tools_exec "dig +short $qdom; echo; nslookup $qdom 2>/dev/null || true; echo; getent hosts $qdom 2>/dev/null || true"
    ;;
  route | net)
    _tools_exec "ip r; echo; ip a; echo; ss -tulpen 2>/dev/null || netstat -tulpen 2>/dev/null || true"
    ;;
  tcp)
    local h="${1:-}"
    local p="${2:-}"
    [[ -n "$h" && -n "$p" ]] || die "diag tcp <host> <port>"
    _tools_exec "nc -vz -w2 $(_shq "$h") $(_shq "$p")"
    ;;
  http)
    local url="${1:-}"
    shift || true
    [[ -n "$url" ]] || die "diag http <url> [curl-args...]"
    local -a qargs=()
    local a
    for a in "$@"; do qargs+=("$(printf '%q' "$a")"); done
    _tools_exec "curl -vkI $(_shq "$url") ${qargs[*]}"
    ;;
  tls)
    local dom="${1:-}"
    [[ -n "$dom" ]] || die "diag tls <domain>"
    local qdom
    qdom="$(_shq "$dom")"
    _tools_exec "echo | openssl s_client -connect ${qdom}:443 -servername $qdom -showcerts 2>/dev/null | sed -n '1,60p'"
    ;;
  *)
    die "diag <dns|route|net|tcp|http|tls>"
    ;;
  esac
}

cmd_sniff() {
  local url="${1:-}"
  shift || true
  [[ -n "$url" ]] || die "sniff <url> [curl-args...]"
  local -a qargs=()
  local a
  for a in "$@"; do qargs+=("$(printf '%q' "$a")"); done
  _tools_exec "curl -vk -D - $(_shq "$url") ${qargs[*]} | (command -v jq >/dev/null 2>&1 && jq . 2>/dev/null || cat)"
}


###############################################################################
# 6w. NEW FEATURES: stack diff | support trace
###############################################################################

# stack diff: show what would run (compose) vs what's running (docker)
cmd_stack_diff() {
  local json=0
  local show_config=0
  while [[ "${1:-}" ]]; do
    case "$1" in
    --json)
      json=1
      shift
      ;;
    --config)
      show_config=1
      shift
      ;;
    *) break ;;
    esac
  done

  local project
  project="$(lds_project)"
  local cfg_json=""

  if docker_compose config --format json >/dev/null 2>&1; then
    cfg_json="$(docker_compose config --format json)"
  else
    # fallback: best-effort text config
    cfg_json=""
  fi

  # running: service -> image
  declare -A running=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local svc="${line%%|*}"
    local img="${line#*|}"
    running["$svc"]="$img"
  done < <(docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --format '{{index .Labels "com.docker.compose.service"}}|{{.Image}}' 2>/dev/null || true)

  # desired: service -> image/build context (best-effort)
  declare -A desired_img=()
  declare -A desired_ctx=()
  declare -A desired_df=()

  if [[ -n "$cfg_json" ]]; then
    if has_tool jq; then
      while IFS= read -r line; do
        local svc="${line%%|*}"
        local img="${line#*|}"
        desired_img["$svc"]="$img"
      done < <(printf '%s' "$cfg_json" | jq -r '.services | to_entries[] | "\(.key)|\(.value.image // "")"')
      while IFS= read -r line; do
        local svc="${line%%|*}"
        local ctx="${line#*|}"
        desired_ctx["$svc"]="$ctx"
      done < <(printf '%s' "$cfg_json" | jq -r '.services | to_entries[] | "\(.key)|\(.value.build.context // "")"')
      while IFS= read -r line; do
        local svc="${line%%|*}"
        local df="${line#*|}"
        desired_df["$svc"]="$df"
      done < <(printf '%s' "$cfg_json" | jq -r '.services | to_entries[] | "\(.key)|\(.value.build.dockerfile // "")"')
    elif _server_tools_has jq; then
      # Fallback: parse via project tools container jq through stdin (no shell re-quoting of JSON payload).
      local ctr
      ctr="$(_project_tools_container_running || true)"
      if [[ -n "$ctr" ]]; then
        while IFS= read -r line; do
          local svc="${line%%|*}"
          local img="${line#*|}"
          desired_img["$svc"]="$img"
        done < <(printf '%s' "$cfg_json" | docker exec -i "$ctr" jq -r '.services | to_entries[] | "\(.key)|\(.value.image // "")"' 2>/dev/null || true)
        while IFS= read -r line; do
          local svc="${line%%|*}"
          local ctx="${line#*|}"
          desired_ctx["$svc"]="$ctx"
        done < <(printf '%s' "$cfg_json" | docker exec -i "$ctr" jq -r '.services | to_entries[] | "\(.key)|\(.value.build.context // "")"' 2>/dev/null || true)
        while IFS= read -r line; do
          local svc="${line%%|*}"
          local df="${line#*|}"
          desired_df["$svc"]="$df"
        done < <(printf '%s' "$cfg_json" | docker exec -i "$ctr" jq -r '.services | to_entries[] | "\(.key)|\(.value.build.dockerfile // "")"' 2>/dev/null || true)
      fi
    fi
  fi

  # Build result object
  if ((json)); then
    if has_tool jq; then
      # assemble in bash -> jq
      local tmp
      tmp="$(mktemp)"
      {
        printf '{'
        printf '"project":%s,' "$(printf '%s' "$project" | jq -Rsa .)"
        printf '"compose_file":%s,' "$(printf '%s' "$COMPOSE_FILE" | jq -Rsa .)"
        printf '"running":{'
        local first=1 k
        for k in "${!running[@]}"; do
          ((first)) || printf ','
          first=0
          printf '%s:%s' "$(printf '%s' "$k" | jq -R .)" "$(printf '%s' "${running[$k]}" | jq -R .)"
        done
        printf '},'
        printf '"desired":{'
        first=1
        for k in "${!desired_img[@]}"; do
          ((first)) || printf ','
          first=0
          printf '%s:%s' "$(printf '%s' "$k" | jq -R .)" "$(printf '%s' "${desired_img[$k]}" | jq -R .)"
        done
        printf '},'
        printf '"diff":['
        first=1
        # union keys
        declare -A seen=()
        for k in "${!running[@]}"; do seen["$k"]=1; done
        for k in "${!desired_img[@]}"; do seen["$k"]=1; done
        for k in "${!seen[@]}"; do
          local r="${running[$k]:-}"
          local d="${desired_img[$k]:-}"
          if [[ "$r" != "$d" ]]; then
            ((first)) || printf ','
            first=0
            printf '{"service":%s,"running":%s,"desired":%s}' \
              "$(printf '%s' "$k" | jq -R .)" \
              "$(printf '%s' "$r" | jq -R .)" \
              "$(printf '%s' "$d" | jq -R .)"
          fi
        done
        printf ']'
        printf '}\n'
      } >"$tmp"
      cat "$tmp" | jq .
      rm -f "$tmp"
    else
      die "jq required for --json (or run inside project server-tools container)"
    fi
    return 0
  fi

  printf "%bStack diff%b (project=%s)\n" "$CYAN" "$NC" "$project"
  printf "%bCompose file:%b %s\n" "$DIM" "$NC" "$COMPOSE_FILE"

  if ((show_config)); then
    if [[ -n "$cfg_json" ]]; then
      printf "\n%bEffective compose config (json):%b\n" "$DIM" "$NC"
      printf '%s\n' "$cfg_json"
    else
      printf "\n%bEffective compose config:%b\n" "$DIM" "$NC"
      docker_compose config || true
    fi
  fi

  # union services
  declare -A all=()
  local svc
  for svc in "${!running[@]}"; do all["$svc"]=1; done
  for svc in "${!desired_img[@]}"; do all["$svc"]=1; done

  printf "\n%-22s  %-40s  %-40s  %s\n" "SERVICE" "RUNNING" "DESIRED" "STATUS"
  printf "%-22s  %-40s  %-40s  %s\n" "------" "-------" "-------" "------"
  for svc in $(printf '%s\n' "${!all[@]}" | sort); do
    local r="${running[$svc]:-}"
    local d="${desired_img[$svc]:-}"
    local st
    if [[ -z "$r" ]]; then
      st="(not running)"
    elif [[ -z "$d" ]]; then
      st="(not in config)"
    elif [[ "$r" == "$d" ]]; then
      st="OK"
    else
      st="DIFF"
    fi
    printf "%-22s  %-40.40s  %-40.40s  %s\n" "$svc" "$r" "$d" "$st"
  done

  printf "\n%bNotes:%b\n" "$DIM" "$NC"
  printf "  - Desired image is derived from 'docker compose config'. If a service uses only 'build:' and no 'image:', desired may be empty.\n"
  printf "  - Use: lds stack diff --config  (to print resolved compose config)\n"
}

# support trace: quick end-to-end trace for a domain
cmd_support_trace() {
  local dom="${1:-}"
  [[ -n "$dom" ]] || die "support trace <domain>"

  local nconf="/etc/share/vhosts/nginx/$dom.conf"
  local nconf_source="server-tools:$nconf"
  local nconf_text="" ctr nginx_ctr
  ctr="$(_project_tools_container_running || true)"
  if [[ -n "$ctr" ]]; then
    nconf_text="$(docker exec "$ctr" sh -c 'cat "$1" 2>/dev/null || true' sh "$nconf" 2>/dev/null || true)"
  else
    nginx_ctr="$(docker_compose ps -q nginx 2>/dev/null | sed -n '1p' || true)"
    if [[ -n "$nginx_ctr" ]] && docker inspect -f '{{.State.Running}}' "$nginx_ctr" 2>/dev/null | grep -qx true; then
      nconf="/etc/nginx/conf.d/$dom.conf"
      nconf_source="nginx:$nconf"
      nconf_text="$(docker exec "$nginx_ctr" sh -c 'cat "$1" 2>/dev/null || true' sh "$nconf" 2>/dev/null || true)"
    fi
  fi
  printf "%bTrace%b: %s\n" "$CYAN" "$NC" "$dom"

  # 1) DNS
  if _server_tools_running; then
    printf "\n%b[DNS]%b\n" "$DIM" "$NC"
    _tools_exec "dig +short $(_shq "$dom") || true; getent hosts $(_shq "$dom") 2>/dev/null || true"
  else
    printf "\n%b[DNS]%b\n" "$DIM" "$NC"
    (has_cmd dig && dig +short "$dom") || true
    (has_cmd getent && getent hosts "$dom") || true
  fi

  # 2) TLS certificate
  printf "\n%b[TLS]%b\n" "$DIM" "$NC"
  if _server_tools_running; then
    _tools_exec "echo | openssl s_client -connect $(_shq "$dom"):443 -servername $(_shq "$dom") -showcerts 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true"
  else
    echo | openssl s_client -connect "${dom}:443" -servername "$dom" -showcerts 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true
  fi

  # 3) HTTP probe (timings)
  printf "\n%b[HTTP]%b\n" "$DIM" "$NC"
  if _server_tools_running; then
    _tools_exec "curl -sk -o /dev/null -D - -w 'time_namelookup=%{time_namelookup}\ntime_connect=%{time_connect}\ntime_appconnect=%{time_appconnect}\ntime_starttransfer=%{time_starttransfer}\ntime_total=%{time_total}\nhttp_code=%{http_code}\n' https://$(_shq "$dom") | sed -n '1,30p'"
  else
    curl -sk -o /dev/null -D - -w $'time_namelookup=%{time_namelookup}\ntime_connect=%{time_connect}\ntime_appconnect=%{time_appconnect}\ntime_starttransfer=%{time_starttransfer}\ntime_total=%{time_total}\nhttp_code=%{http_code}\n' "https://$dom" | sed -n '1,30p'
  fi

  # 4) Upstream inference from the persisted NginxHosts state.
  printf "\n%b[Upstream]%b\n" "$DIM" "$NC"
  if [[ -n "$nconf_text" ]]; then
    if grep -q fastcgi_pass <<<"$nconf_text"; then
      local php
      php="$(grep -Eo 'fastcgi_pass[[:space:]]+[^;]+' <<<"$nconf_text" | awk '{print $2}' | head -n1 || true)"
      printf "type=php\nfastcgi_pass=%s\n" "${php:-unknown}"
    elif grep -q proxy_pass <<<"$nconf_text"; then
      local up
      up="$(grep -m1 -Eo 'proxy_pass[[:space:]]+http[s]?://[^;]+' <<<"$nconf_text" | awk '{print $2}' | head -n1 || true)"
      printf "type=proxy\nproxy_pass=%s\n" "${up:-unknown}"
    else
      printf "type=static\n"
    fi
  else
    printf "nginx_conf=%s (missing or unavailable)\n" "$nconf_source"
  fi

  # 5) Recent nginx logs (compose)
  printf "\n%b[Recent nginx logs]%b\n" "$DIM" "$NC"
  docker_compose logs --no-color --tail 120 nginx 2>/dev/null | text_grep -i "$dom" || docker_compose logs --no-color --tail 120 nginx 2>/dev/null || true

  printf "\n%bDone.%b If this still looks wrong, run: lds diag tls %s\n" "$GREEN" "$NC" "$dom"
}



###############################################################################
# PRODUCT CONFIG / IMAGES / DOCTOR
###############################################################################

_redact_effective_config() {
  sed -E \
    -e 's/^([[:space:]]*[A-Z0-9_]*(PASSWORD|SECRET|TOKEN|PRIVATE_KEY|API_KEY|ACCESS_KEY)[A-Z0-9_]*:[[:space:]]*).*$/\1"***REDACTED***"/' \
    -e 's/^([[:space:]]*(ME_CONFIG_MONGODB_URL|DATABASE_URL):[[:space:]]*).*$/\1"***REDACTED***"/' \
    -e 's/("[A-Z0-9_]*(PASSWORD|SECRET|TOKEN|PRIVATE_KEY|API_KEY|ACCESS_KEY)[A-Z0-9_]*"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"***REDACTED***"/g' \
    -e 's/("(ME_CONFIG_MONGODB_URL|DATABASE_URL)"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"***REDACTED***"/g'
}

_redact_support_text() {
  _redact_effective_config | sed -E \
    -e 's/((password|secret|token|api[_-]?key|access[_-]?key)[=:][[:space:]]*)[^[:space:]]+/\1***REDACTED***/Ig'
}

_env_key_list() {
  local file="${1:-}" source="${2:-}"
  [[ -r "$file" ]] || return 0
  awk -F= -v source="$source" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ { print source "\t" $1 }
  ' "$file"
}

_validate_scheduler_text() {
  local file failed=0
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    if grep -Iq . "$file" && grep -q $'\r$' "$file"; then
      printf '%b[fail]%b CRLF scheduler file: %s\n' "$RED" "$NC" "$file" >&2
      failed=1
    fi
  done < <(find "$DIR/configuration/scheduler" -type f ! -name '.gitignore' -print 2>/dev/null | sort)
  return "$failed"
}

cmd_config() {
  local sub="${1:-show}"
  shift || true

  case "${sub,,}" in
  show | "")
    local format="" raw=0
    while [[ "${1:-}" ]]; do
      case "$1" in
      --json) format=json; shift ;;
      --raw) raw=1; shift ;;
      *) die "config show [--json] [--raw]" ;;
      esac
    done

    local -a args=(config)
    [[ "$format" == json ]] && args+=(--format json)
    if ((raw)); then
      warn "Printing raw effective configuration; secret values may be visible."
      docker_compose "${args[@]}"
    else
      docker_compose "${args[@]}" | _redact_effective_config
    fi
    ;;
  services)
    docker_compose config --services
    ;;
  profiles)
    docker_compose config --profiles
    ;;
  env-used)
    {
      _env_key_list "$ENV_RELEASE" release
      _env_key_list "$ENV_DOCKER" user
    } | LC_ALL=C sort -k2,2 -k1,1
    ;;
  validate)
    docker_compose config --quiet
    _validate_scheduler_text || die "Scheduler files contain CRLF; convert them to LF before Runner consumes them."

    local runner
    runner="$(docker_compose ps -q runner 2>/dev/null | sed -n '1p' || true)"
    if [[ -n "$runner" ]] && docker inspect -f '{{.State.Running}}' "$runner" 2>/dev/null | grep -qx true; then
      docker exec "$runner" supervisord -t -c /etc/supervisor/supervisord.conf >/dev/null
      ok "Compose and mounted Supervisor configuration validate."
    else
      ok "Compose configuration validates."
      warn "Runner is not running; Supervisor syntax check skipped."
    fi

    local -a fragments=()
    mapfile -t fragments < <(find "$EXTRAS_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null | sort)
    if (("${#fragments[@]}" > 0)); then
      printf '%bGenerated Compose fragments:%b\n' "$CYAN" "$NC"
      printf '  %s\n' "${fragments[@]}"
    fi
    ;;
  *)
    die "config <show|services|profiles|env-used|validate>"
    ;;
  esac
}

cmd_images() {
  local elastic
  elastic="$(compose_control_value ELASTICSEARCH_VERSION latest)"

  printf '%-16s %s\n' "Tools" "infocyph/tools:latest"
  printf '%-16s %s\n' "Runner" "infocyph/runner:latest"
  printf '%-16s %s\n' "Nginx" "infocyph/nginx:latest"
  printf '%-16s %s\n' "Apache" "infocyph/apache:latest"
  local ai_runtime llm_arch
  ai_runtime="$(compose_control_value LDS_AI_RUNTIME "")"
  [[ -n "$ai_runtime" ]] || ai_runtime="$(detect_ai_runtime)"
  llm_arch="$(llm_arch_for_runtime "$ai_runtime")"
  printf '%-16s %s\n' "LLM" "infocyph/llm-ollama:$llm_arch"
  printf '%-16s %s\n' "LLM runtime" "$ai_runtime"
  printf '%-16s postgres:%s\n' "PostgreSQL" "$(compose_control_value POSTGRES_VERSION alpine)"
  printf '%-16s mysql:%s\n' "MySQL" "$(compose_control_value MYSQL_VERSION latest)"
  printf '%-16s mariadb:%s\n' "MariaDB" "$(compose_control_value MARIADB_VERSION latest)"
  printf '%-16s mongo:%s\n' "MongoDB" "$(compose_control_value MONGODB_VERSION latest)"
  printf '%-16s redis/redis-stack-server:%s\n' "Redis" "$(compose_control_value REDIS_VERSION latest)"
  printf '%-16s elasticsearch:%s\n' "Elasticsearch" "$elastic"
  printf '%-16s kibana:%s\n' "Kibana" "$elastic"
  printf '%-16s docker.elastic.co/beats/filebeat:%s\n' "Filebeat" "$elastic"
  printf '%-16s %s\n' "PHP runtimes" "localdevstack-php:<selected-version> (Alpine)"
  printf '%-16s %s\n' "Node runtimes" "localdevstack-node:<selected-version> (Alpine)"
}

_doctor_ok() { printf '%b[ok]%b   %s\n' "$GREEN" "$NC" "$*"; }
_doctor_warn() { printf '%b[warn]%b %s\n' "$YELLOW" "$NC" "$*"; }
_doctor_fail() { printf '%b[fail]%b %s\n' "$RED" "$NC" "$*" >&2; }

cmd_doctor() {
  local failures=0 warnings=0 project ctr status name
  project="$(lds_project)"

  if ! has_bin docker; then
    _doctor_fail "Docker CLI is not installed."
    return 1
  fi
  _doctor_ok "Docker CLI: $(docker --version 2>/dev/null || printf unknown)"

  if ! docker info >/dev/null 2>&1; then
    _doctor_fail "Docker daemon is unavailable."
    return 1
  fi
  _doctor_ok "Docker daemon is reachable."

  if docker compose version >/dev/null 2>&1 || has_bin docker-compose; then
    _doctor_ok "Docker Compose is available."
  else
    _doctor_fail "Docker Compose is unavailable."
    failures=$((failures + 1))
  fi

  if docker_compose config --quiet >/dev/null 2>&1; then
    _doctor_ok "Effective Compose configuration validates."
  else
    _doctor_fail "Effective Compose configuration is invalid."
    failures=$((failures + 1))
  fi

  printf '%bProfiles:%b %s\n' "$CYAN" "$NC" "$(_enabled_profiles_csv | sed 's/^$/<none>/')"

  for name in Frontend Backend DataStore; do
    if docker network inspect "$name" >/dev/null 2>&1; then
      _doctor_ok "Network present: $name"
    else
      _doctor_warn "Network not created yet: $name"
      warnings=$((warnings + 1))
    fi
  done

  ctr="$(_project_tools_container_running || true)"
  if [[ -n "$ctr" ]]; then
    _doctor_ok "Tools container is running: $ctr"
    if docker exec "$ctr" sh -ec 'test -s /etc/mkcert/lds-server.pem && test -s /etc/mkcert/lds-server-key.pem' >/dev/null 2>&1; then
      _doctor_ok "Shared TLS certificate/key are present."
    else
      _doctor_warn "Shared TLS certificate/key are not ready."
      warnings=$((warnings + 1))
    fi
  else
    _doctor_warn "Tools container is not running."
    warnings=$((warnings + 1))
  fi

  while IFS='|' read -r name status; do
    [[ -n "$name" ]] || continue
    if [[ "$status" == *"(unhealthy)"* ]]; then
      _doctor_fail "$name: $status"
      failures=$((failures + 1))
    else
      _doctor_ok "$name: $status"
    fi
  done < <(
    docker ps \
      --filter "label=com.docker.compose.project=$project" \
      --format '{{.Names}}|{{.Status}}' 2>/dev/null || true
  )

  if profile_enabled ai; then
    local llm
    llm="$(docker_compose ps -q llm-ollama 2>/dev/null | sed -n '1p' || true)"
    if [[ -n "$llm" ]] && docker inspect -f '{{.State.Running}}' "$llm" 2>/dev/null | grep -qx true; then
      _doctor_ok "AI provider container is running."
    else
      _doctor_warn "AI profile is selected but llm-ollama is not running."
      warnings=$((warnings + 1))
    fi
  fi

  printf '%bDoctor summary:%b %d failure(s), %d warning(s)\n' "$CYAN" "$NC" "$failures" "$warnings"
  ((failures == 0))
}
