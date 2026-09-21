# shellcheck shell=bash
###############################################################################
# 1c. HTTP / WEB SERVER HELPERS
###############################################################################

http_reload() {
  printf "%bReloading HTTP...%b" "$MAGENTA" "$NC"
  docker ps -qf name=NGINX &>/dev/null && docker exec NGINX nginx -s reload &>/dev/null || true
  docker ps -qf name=APACHE &>/dev/null && docker exec APACHE apachectl graceful &>/dev/null || true
  printf "\r%bHTTP reloaded!   %b\n" "$GREEN" "$NC"
}


###############################################################################
# 3. DOMAIN / PROFILE INTEGRATION
###############################################################################
mkhost() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  docker exec "$ctr" mkhost "$@"
}
rmhost() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  docker exec "$ctr" rmhost "$@"
}

setup_domain() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"

  mkhost --RESET
  docker exec -it "$ctr" mkhost
  local mk_state svr_prof
  mk_state="$(mkhost --JSON || true)"
  if has_tool jq; then
    svr_prof="$(printf '%s' "$mk_state" | jq -r '.state.apache_active // empty' 2>/dev/null || true)"
  else
    svr_prof="$(printf '%s' "$mk_state" | tr -d '\r\n' | sed -n 's/.*"apache_active"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  [[ -n $svr_prof ]] && modify_profiles add "$svr_prof"
  mkhost --RESET
  cmd_reboot
}

delete_domain() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"

  rmhost --RESET

  # interactive delete
  docker exec -it "$ctr" rmhost "$@"

  local rm_state apache_cont
  rm_state="$(rmhost --JSON || true)"
  if has_tool jq; then
    apache_cont="$(printf '%s' "$rm_state" | jq -r '.state.apache_delete // empty' 2>/dev/null || true)"
  else
    apache_cont="$(printf '%s' "$rm_state" | tr -d '\r\n' | sed -n 's/.*"apache_delete"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  [[ -n "$apache_cont" ]] && modify_profiles remove "$apache_cont"

  rmhost --RESET
  cmd_reboot
}

modify_profiles() {
  local action=$1
  shift
  local file=$ENV_DOCKER var=COMPOSE_PROFILES
  local -a existing updated

  if [[ -r $file ]]; then
    local line value
    line=$(grep -E "^${var}=" "$file" | tail -n1 || true)
    value=${line#*=}
    IFS=',' read -r -a existing <<<"$value"
  fi

  case $action in
  add)
    local p
    for p; do
      [[ -n $p && ! " ${existing[*]} " =~ " $p " ]] && updated+=("$p")
    done
    updated+=("${existing[@]}")
    ;;
  remove)
    local old
    for old in "${existing[@]}"; do
      [[ ! " $* " =~ " $old " ]] && updated+=("$old")
    done
    ;;
  *) die "modify_profiles: invalid action '$action'" ;;
  esac

  update_env "$file" "$var" "$(
    IFS=,
    echo "${updated[*]}"
  )"
}

