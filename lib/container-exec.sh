# shellcheck shell=bash
# Shared container target resolution and execution substrate.

_CONTAINER_TARGET_KIND=''
_CONTAINER_TARGET_REQUESTED=''
_CONTAINER_TARGET_SERVICE=''
_CONTAINER_TARGET_ID=''
_CONTAINER_TARGET_NAME=''
declare -a _CONTAINER_EXEC_FLAGS=()

_container_target_reset() {
  _CONTAINER_TARGET_KIND=''
  _CONTAINER_TARGET_REQUESTED=''
  _CONTAINER_TARGET_SERVICE=''
  _CONTAINER_TARGET_ID=''
  _CONTAINER_TARGET_NAME=''
}

_container_project_service_exists() {
  local want="${1:-}" service
  [[ -n "$want" ]] || return 1
  while IFS= read -r service; do
    [[ "$service" == "$want" ]] && return 0
  done < <(docker_compose config --services 2>/dev/null || true)
  return 1
}

_container_name_from_id() {
  local id="${1:-}" name
  [[ -n "$id" ]] || return 1
  name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null || true)"
  name="${name#/}"
  [[ -n "$name" ]] || return 1
  printf '%s' "$name"
}

_container_resolve_target() {
  local target="${1:-}" id name service
  local -a ids=()

  _container_target_reset
  [[ -n "$target" ]] || {
    err "Container/service target is required"
    return 64
  }
  _CONTAINER_TARGET_REQUESTED="$target"

  # Current-project Compose service names win over global Docker names.
  if _container_project_service_exists "$target"; then
    mapfile -t ids < <(docker_compose ps -a -q "$target" 2>/dev/null | awk 'NF')
    if (("${#ids[@]}" == 0)); then
      err "Service container is not created: $target"
      return 66
    fi
    if (("${#ids[@]}" > 1)); then
      err "Service resolves to multiple containers: $target"
      return 65
    fi

    id="${ids[0]}"
    name="$(_container_name_from_id "$id" || true)"
    [[ -n "$name" ]] || name="$id"

    _CONTAINER_TARGET_KIND=service
    _CONTAINER_TARGET_SERVICE="$target"
    _CONTAINER_TARGET_ID="$id"
    _CONTAINER_TARGET_NAME="$name"
    return 0
  fi

  # Otherwise preserve exact Docker container names/IDs as an explicit escape.
  id="$(docker inspect -f '{{.Id}}' "$target" 2>/dev/null || true)"
  [[ -n "$id" ]] || {
    err "Container or current-project service not found: $target"
    return 66
  }

  name="$(_container_name_from_id "$id" || true)"
  [[ -n "$name" ]] || name="$target"
  service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null || true)"

  _CONTAINER_TARGET_KIND=container
  _CONTAINER_TARGET_SERVICE="$service"
  _CONTAINER_TARGET_ID="$id"
  _CONTAINER_TARGET_NAME="$name"
}

_container_require_running() {
  local target="${1:-}" running
  [[ -n "$target" ]] || {
    err "Container target is required"
    return 64
  }

  running="$(docker inspect -f '{{.State.Running}}' "$target" 2>/dev/null || true)"
  [[ "$running" == true ]] || {
    err "Container is not running: $target"
    return 69
  }
}

_container_stdin_is_tty() { [[ -t 0 ]]; }
_container_stdout_is_tty() { [[ -t 1 ]]; }
_container_stdin_has_data() { [[ -p /dev/stdin || -f /dev/stdin ]]; }

_container_exec_flags() {
  local mode="${1:-command}"
  _CONTAINER_EXEC_FLAGS=()

  case "$mode" in
  shell)
    _CONTAINER_EXEC_FLAGS=(-it)
    ;;
  command)
    if _container_stdin_is_tty && _container_stdout_is_tty; then
      _CONTAINER_EXEC_FLAGS=(-it)
    elif _container_stdin_is_tty || _container_stdin_has_data; then
      _CONTAINER_EXEC_FLAGS=(-i)
    fi
    ;;
  *)
    err "Unknown container execution mode: $mode"
    return 64
    ;;
  esac
}

_container_exec_argv() {
  local target="${1:-}" workdir=''
  shift || true

  if [[ "${1:-}" == --workdir ]]; then
    workdir="${2:-}"
    [[ -n "$workdir" ]] || {
      err "--workdir requires a path"
      return 64
    }
    shift 2
  fi
  [[ "${1:-}" == -- ]] && shift
  (($# > 0)) || {
    err "Container command is required"
    return 64
  }

  _container_require_running "$target" || return $?
  _container_exec_flags command || return $?

  local -a args=(docker exec "${_CONTAINER_EXEC_FLAGS[@]}")
  [[ -n "$workdir" ]] && args+=(--workdir "$workdir")
  args+=("$target" "$@")
  "${args[@]}"
}

_container_first_existing_dir() {
  local target="${1:-}"
  shift || true
  _container_require_running "$target" || return $?

  local path
  for path in "$@"; do
    [[ -n "$path" ]] || continue
    if docker exec "$target" test -d "$path" >/dev/null 2>&1; then
      printf '%s' "$path"
      return 0
    fi
  done

  printf '%s' /
}

_container_shell_name() {
  local target="${1:-}"
  _container_require_running "$target" || return $?
  if docker exec "$target" sh -lc 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
    printf '%s' bash
  else
    printf '%s' sh
  fi
}

_container_open_shell() {
  local target="${1:-}" workdir=''
  shift || true

  if [[ "${1:-}" == --workdir ]]; then
    workdir="${2:-}"
    [[ -n "$workdir" ]] || {
      err "--workdir requires a path"
      return 64
    }
    shift 2
  fi
  (($# == 0)) || {
    err "Unexpected shell arguments: $*"
    return 64
  }

  local shell
  shell="$(_container_shell_name "$target")" || return $?
  _container_exec_flags shell || return $?

  local -a args=(docker exec "${_CONTAINER_EXEC_FLAGS[@]}")
  [[ -n "$workdir" ]] && args+=(--workdir "$workdir")
  args+=("$target")
  if [[ "$shell" == bash ]]; then
    args+=(bash --login)
  else
    args+=(sh)
  fi
  "${args[@]}"
}
