#!/usr/bin/env bash
# Shared container/domain execution substrate for LDS host commands.

LDS_CONTAINER_ID=''
LDS_CONTAINER_NAME=''
LDS_CONTAINER_SERVICE=''
LDS_CONTAINER_KIND=''
LDS_CONTAINER_ERROR=''
LDS_CORE_DOMAIN=''
LDS_CORE_APP=''
LDS_CORE_CONTAINER=''
LDS_CORE_WORKDIR=''
declare -a LDS_CONTAINER_EXEC_FLAGS=()

_container_reset_resolution() {
  LDS_CONTAINER_ID=''
  LDS_CONTAINER_NAME=''
  LDS_CONTAINER_SERVICE=''
  LDS_CONTAINER_KIND=''
  LDS_CONTAINER_ERROR=''
}

_container_docker() {
  if [[ -n "${MSYSTEM:-}${CYGWIN:-}" ]]; then
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"
  else
    docker "$@"
  fi
}

_container_service_candidate() {
  local requested="${1:-}" candidate
  [[ -n "$requested" ]] || return 1

  candidate="$requested"
  if declare -F resolve_service >/dev/null 2>&1; then
    candidate="$(resolve_service "$requested" 2>/dev/null || true)"
    [[ -n "$candidate" ]] || candidate="$requested"
  fi

  if declare -F compose_service_exists >/dev/null 2>&1 && compose_service_exists "$candidate"; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

_container_resolve_target() {
  local requested="${1:-}" service='' id='' name='' running='' ids=''
  _container_reset_resolution

  if [[ -z "$requested" ]]; then
    LDS_CONTAINER_ERROR='missing'
    return 64
  fi

  service="$(_container_service_candidate "$requested" || true)"
  if [[ -n "$service" ]]; then
    ids="$(docker_compose ps -a -q "$service" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
    if [[ -z "$ids" ]]; then
      LDS_CONTAINER_ERROR='stopped'
      LDS_CONTAINER_SERVICE="$service"
      return 69
    fi
    if [[ "$(printf '%s\n' "$ids" | wc -l | tr -d '[:space:]')" -ne 1 ]]; then
      LDS_CONTAINER_ERROR='ambiguous'
      LDS_CONTAINER_SERVICE="$service"
      return 65
    fi
    id="$(printf '%s\n' "$ids" | sed -n '1p')"
    running="$(_container_docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)"
    if [[ "$running" != true ]]; then
      LDS_CONTAINER_ERROR='stopped'
      LDS_CONTAINER_SERVICE="$service"
      LDS_CONTAINER_ID="$id"
      return 69
    fi
    name="$(_container_docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##' || true)"
    LDS_CONTAINER_ID="$id"
    LDS_CONTAINER_NAME="${name:-$id}"
    LDS_CONTAINER_SERVICE="$service"
    LDS_CONTAINER_KIND='service'
    return 0
  fi

  if ! _container_docker inspect "$requested" >/dev/null 2>&1; then
    LDS_CONTAINER_ERROR='missing'
    return 67
  fi
  running="$(_container_docker inspect -f '{{.State.Running}}' "$requested" 2>/dev/null || true)"
  if [[ "$running" != true ]]; then
    LDS_CONTAINER_ERROR='stopped'
    return 69
  fi
  id="$(_container_docker inspect -f '{{.Id}}' "$requested" 2>/dev/null || true)"
  name="$(_container_docker inspect -f '{{.Name}}' "$requested" 2>/dev/null | sed 's#^/##' || true)"
  LDS_CONTAINER_ID="${id:-$requested}"
  LDS_CONTAINER_NAME="${name:-$requested}"
  LDS_CONTAINER_KIND='container'
  return 0
}

_container_require_running() {
  local requested="${1:-}" rc=0
  if _container_resolve_target "$requested"; then
    return 0
  else
    rc=$?
  fi

  case "$LDS_CONTAINER_ERROR" in
    missing) die "Unknown service/container: $requested" ;;
    stopped)
      if [[ -n "$LDS_CONTAINER_SERVICE" ]]; then
        die "Service is not running: $LDS_CONTAINER_SERVICE"
      fi
      die "Container is not running: $requested"
      ;;
    ambiguous) die "Service resolves to multiple containers; specify an exact container: $requested" ;;
    *) die "Unable to resolve service/container: $requested (exit $rc)" ;;
  esac
}

_container_stdin_is_tty() { [[ -t 0 ]]; }
_container_stdout_is_tty() { [[ -t 1 ]]; }

_container_exec_flags() {
  local mode="${1:-command}"
  LDS_CONTAINER_EXEC_FLAGS=()

  if [[ "$mode" == shell ]]; then
    if ! _container_stdin_is_tty || ! _container_stdout_is_tty; then
      LDS_CONTAINER_ERROR='tty-required'
      return 64
    fi
    LDS_CONTAINER_EXEC_FLAGS=(-i -t)
    return 0
  fi

  _container_stdin_is_tty && LDS_CONTAINER_EXEC_FLAGS+=(-i)
  if _container_stdin_is_tty && _container_stdout_is_tty; then
    LDS_CONTAINER_EXEC_FLAGS+=(-t)
  fi
}

_container_exec_argv() {
  local ctr="${1:-}" workdir="${2:-}"
  shift 2 || true
  [[ -n "$ctr" ]] || die "container id/name required"
  (($#)) || die "container command required"

  _container_exec_flags command
  local -a args=(exec "${LDS_CONTAINER_EXEC_FLAGS[@]}")
  [[ -n "$workdir" ]] && args+=(-w "$workdir")
  args+=("$ctr" "$@")
  _container_docker "${args[@]}"
}

_container_shell_path() {
  local ctr="${1:-}" shell
  [[ -n "$ctr" ]] || return 1
  shell="$(_container_docker exec "$ctr" sh -c '
    if command -v bash >/dev/null 2>&1; then
      printf "%s" bash
    else
      printf "%s" sh
    fi
  ' 2>/dev/null || true)"
  [[ "$shell" == bash || "$shell" == sh ]] || shell=sh
  printf '%s' "$shell"
}

_container_existing_workdir() {
  local ctr="${1:-}" preferred="${2:-}" resolved=''
  [[ -n "$ctr" ]] || return 1

  if [[ -n "$preferred" ]] && _container_docker exec "$ctr" sh -c '[ -d "$1" ]' sh "$preferred" >/dev/null 2>&1; then
    resolved="$preferred"
  elif _container_docker exec "$ctr" sh -c '[ -d /app ]' >/dev/null 2>&1; then
    resolved='/app'
  else
    resolved='/'
  fi
  printf '%s' "$resolved"
}

_container_open_shell() {
  local ctr="${1:-}" workdir="${2:-}" shell
  [[ -n "$ctr" ]] || die "container id/name required"

  if ! _container_exec_flags shell; then
    die "Interactive shell requires a TTY"
  fi
  shell="$(_container_shell_path "$ctr")"

  local -a args=(exec "${LDS_CONTAINER_EXEC_FLAGS[@]}")
  [[ -n "$workdir" ]] && args+=(-w "$workdir")
  args+=("$ctr" "$shell")
  [[ "$shell" == bash ]] && args+=(--login)
  _container_docker "${args[@]}"
}

_core_domain_list() {
  local tools_ctr
  tools_ctr="$(_project_tools_container_running || true)"
  [[ -n "$tools_ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  _container_docker exec "$tools_ctr" domain-which --list-domains 2>/dev/null |
    sed '/^[[:space:]]*$/d' |
    LC_ALL=C sort -u
}

_core_domain_resolve() {
  local domain="${1:-}" tools_ctr app container wd
  [[ -n "$domain" ]] || die "domain required"

  tools_ctr="$(_project_tools_container_running || true)"
  [[ -n "$tools_ctr" ]] || die "server-tools container is not running for project: $(lds_project)"

  app="$(_container_docker exec "$tools_ctr" domain-which --app --quiet "$domain" 2>/dev/null)" ||
    die "Unknown domain: $domain"
  container="$(_container_docker exec "$tools_ctr" domain-which --container --quiet "$domain" 2>/dev/null)" ||
    die "No container resolved for: $domain"
  wd="$(_container_docker exec "$tools_ctr" domain-which --docroot --quiet "$domain" 2>/dev/null || true)"
  [[ -n "$container" ]] || die "No container resolved for: $domain"

  _container_require_running "$container"
  container="$LDS_CONTAINER_ID"

  if [[ "$app" == node ]]; then
    wd='/app'
  fi
  wd="$(_container_existing_workdir "$container" "${wd:-/app}")"

  LDS_CORE_DOMAIN="$domain"
  LDS_CORE_APP="$app"
  LDS_CORE_CONTAINER="$container"
  LDS_CORE_WORKDIR="$wd"
}
