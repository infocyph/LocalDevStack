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

  local nconf="$DIR/configuration/nginx/$dom.conf"
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

  # 4) Upstream inference from nginx conf (if exists)
  printf "\n%b[Upstream]%b\n" "$DIM" "$NC"
  if [[ -r "$nconf" ]]; then
    if grep -q fastcgi_pass "$nconf"; then
      local php
      php="$(grep -Eo 'fastcgi_pass[[:space:]]+[^;]+' "$nconf" | awk '{print $2}' | head -n1 || true)"
      printf "type=php\nfastcgi_pass=%s\n" "${php:-unknown}"
    elif grep -q proxy_pass "$nconf"; then
      local up
      up="$(grep -m1 -Eo 'proxy_pass[[:space:]]+http[s]?://[^;]+' "$nconf" | awk '{print $2}' | head -n1 || true)"
      printf "type=proxy\nproxy_pass=%s\n" "${up:-unknown}"
    else
      printf "type=static\n"
    fi
  else
    printf "nginx_conf=%s (missing)\n" "$nconf"
  fi

  # 5) Recent nginx logs (compose)
  printf "\n%b[Recent nginx logs]%b\n" "$DIM" "$NC"
  docker_compose logs --no-color --tail 120 nginx 2>/dev/null | text_grep -i "$dom" || docker_compose logs --no-color --tail 120 nginx 2>/dev/null || true

  printf "\n%bDone.%b If this still looks wrong, run: lds diag tls %s\n" "$GREEN" "$NC" "$dom"
}

