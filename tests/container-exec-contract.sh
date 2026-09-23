#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/container-exec.log"

err() {
  printf 'err:%s\n' "$*" >>"$log"
}

docker_compose() {
  case "${1:-} ${2:-}" in
    "config --services")
      printf '%s\n' php84 nginx multi
      return 0
      ;;
  esac

  if [[ "${1:-}" == ps && "${2:-}" == -a && "${3:-}" == -q ]]; then
    case "${4:-}" in
      php84) printf '%s\n' cid-php84 ;;
      nginx) printf '%s\n' cid-nginx ;;
      multi) printf '%s\n' cid-one cid-two ;;
    esac
    return 0
  fi

  return 1
}

docker() {
  if [[ "${1:-}" == inspect ]]; then
    if [[ "${2:-}" == -f ]]; then
      case "${2:-}|${3:-}|${4:-}" in
        "-f|{{.Name}}|cid-php84") printf '%s\n' /PHP84 ;;
        "-f|{{.Name}}|cid-nginx") printf '%s\n' /NGINX ;;
        "-f|{{.Name}}|cid-one") printf '%s\n' /ONE ;;
        "-f|{{.Name}}|cid-two") printf '%s\n' /TWO ;;
        "-f|{{.Name}}|cid-custom") printf '%s\n' /MixedCaseContainer ;;
        "-f|{{.Id}}|custom") printf '%s\n' cid-custom ;;
        "-f|{{.Id}}|stopped") printf '%s\n' cid-stopped ;;
        "-f|{{.Name}}|cid-stopped") printf '%s\n' /StoppedContainer ;;
        "-f|{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-custom") printf '%s\n' external-service ;;
        "-f|{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-stopped") printf '\n' ;;
        "-f|{{.State.Running}}|cid-php84") printf '%s\n' true ;;
        "-f|{{.State.Running}}|cid-nginx") printf '%s\n' true ;;
        "-f|{{.State.Running}}|cid-custom") printf '%s\n' true ;;
        "-f|{{.State.Running}}|cid-stopped") printf '%s\n' false ;;
        *) return 1 ;;
      esac
      return 0
    fi
  fi

  if [[ "${1:-}" == exec ]]; then
    printf 'exec:' >>"$log"
    printf ' <%s>' "$@" >>"$log"
    printf '\n' >>"$log"

    case " $* " in
      *" cid-php84 sh -lc command -v bash >/dev/null 2>&1 "*) return 0 ;;
      *" cid-nginx sh -lc command -v bash >/dev/null 2>&1 "*) return 1 ;;
      *" cid-custom sh -lc command -v bash >/dev/null 2>&1 "*) return 0 ;;
    esac
    return 0
  fi

  return 1
}

# shellcheck source=lib/container-exec.sh
source "$ROOT/lib/container-exec.sh"

_container_resolve_target php84
[[ "$_CONTAINER_TARGET_KIND" == service ]] || fail "service target kind drifted"
[[ "$_CONTAINER_TARGET_SERVICE" == php84 ]] || fail "service name drifted"
[[ "$_CONTAINER_TARGET_ID" == cid-php84 ]] || fail "service id drifted"
[[ "$_CONTAINER_TARGET_NAME" == PHP84 ]] || fail "service container name drifted"
pass "shared resolver prefers current-project Compose services"

_container_resolve_target custom
[[ "$_CONTAINER_TARGET_KIND" == container ]] || fail "explicit container target kind drifted"
[[ "$_CONTAINER_TARGET_ID" == cid-custom ]] || fail "explicit container id drifted"
[[ "$_CONTAINER_TARGET_NAME" == MixedCaseContainer ]] || fail "explicit container case was not preserved"
[[ "$_CONTAINER_TARGET_SERVICE" == external-service ]] || fail "explicit container service label drifted"
pass "shared resolver preserves exact explicit container targets"

set +e
_container_resolve_target multi >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 65 ]] || fail "ambiguous service returned $rc instead of 65"
assert_file_contains "$log" 'err:Service resolves to multiple containers: multi'
pass "shared resolver rejects ambiguous Compose services"

set +e
_container_resolve_target missing >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 66 ]] || fail "missing target returned $rc instead of 66"
assert_file_contains "$log" 'err:Container or current-project service not found: missing'
pass "shared resolver reports missing targets"

_container_resolve_target stopped
set +e
_container_require_running "$_CONTAINER_TARGET_ID" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 69 ]] || fail "stopped target returned $rc instead of 69"
assert_file_contains "$log" 'err:Container is not running: cid-stopped'
pass "shared execution validates running state"

_container_stdin_is_tty() { return 0; }
_container_stdout_is_tty() { return 0; }
_container_stdin_has_data() { return 0; }
_container_exec_flags command
[[ "${_CONTAINER_EXEC_FLAGS[*]}" == "-it" ]] || fail "interactive command flags drifted: ${_CONTAINER_EXEC_FLAGS[*]}"
pass "interactive command gets stdin and TTY"

_container_stdin_is_tty() { return 1; }
_container_stdout_is_tty() { return 1; }
_container_stdin_has_data() { return 0; }
_container_exec_flags command
[[ "${_CONTAINER_EXEC_FLAGS[*]}" == "-i" ]] || fail "piped command flags drifted: ${_CONTAINER_EXEC_FLAGS[*]}"
pass "piped command keeps stdin without forcing TTY"

_container_stdin_is_tty() { return 1; }
_container_stdout_is_tty() { return 1; }
_container_stdin_has_data() { return 1; }
_container_exec_flags command
[[ "${#_CONTAINER_EXEC_FLAGS[@]}" -eq 0 ]] || fail "non-interactive no-input command received unnecessary flags"
pass "non-interactive command without stdin gets no TTY flags"

_container_stdin_is_tty() { return 1; }
_container_stdout_is_tty() { return 1; }
set +e
_container_exec_flags shell >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "non-TTY interactive shell returned $rc instead of 64"
pass "interactive shell rejects non-TTY invocation"

_container_stdin_is_tty() { return 0; }
_container_stdout_is_tty() { return 0; }
_container_exec_flags shell
[[ "${_CONTAINER_EXEC_FLAGS[*]}" == "-it" ]] || fail "interactive shell flags drifted"
pass "interactive shell receives stdin and TTY when available"

# Explicit argv must remain separate Docker arguments, including spaces and shell metacharacters.
: >"$log"
_container_stdin_is_tty() { return 1; }
_container_stdout_is_tty() { return 1; }
_container_stdin_has_data() { return 1; }
_container_exec_argv cid-custom --workdir '/app path' -- printf '%s|%s' 'hello world' '$(danger)'
assert_file_contains "$log" 'exec: <exec> <--workdir> </app path> <cid-custom> <printf> <%s|%s> <hello world> <$(danger)>'
pass "shared executor preserves argv and working directory without host interpolation"

: >"$log"
_container_exec_interactive_argv cid-custom --workdir '/app path' -- lazydocker --debug
assert_file_contains "$log" 'exec: <exec> <-it> <--workdir> </app path> <cid-custom> <lazydocker> <--debug>'
pass "shared interactive argv helper requires and preserves TTY execution"

: >"$log"
_container_open_shell cid-php84 --workdir /app
assert_file_contains "$log" 'exec: <exec> <-it> <--workdir> </app> <cid-php84> <bash> <--login>'
pass "shared shell helper prefers Bash and supports Docker workdir"


: >"$log"
_container_open_shell cid-nginx
assert_file_contains "$log" 'exec: <exec> <-it> <cid-nginx> <sh>'
pass "shared shell helper falls back to sh"

: >"$log"
docker() {
  if [[ "${1:-}" == inspect && "${2:-}" == -f && "${3:-}" == '{{.State.Running}}' ]]; then
    printf '%s\n' true
    return 0
  fi
  if [[ "${1:-}" == exec && "${2:-}" == cid-php84 && "${3:-}" == test && "${4:-}" == -d ]]; then
    case "${5:-}" in
      /missing) return 1 ;;
      /app) return 0 ;;
    esac
  fi
  return 0
}
resolved_dir="$(_container_first_existing_dir cid-php84 /missing /app /)"
[[ "$resolved_dir" == /app ]] || fail "workdir fallback resolved '$resolved_dir' instead of /app"
pass "shared workdir resolver selects the first existing container directory"


# Cross-platform wrapper behavior is isolated in subshells so environment
# overrides do not affect the Linux contracts above.
msys_log="$tmp/msys.log"
(
  set -euo pipefail
  err() { :; }
  docker() {
    printf 'env:%s:%s args:' "${MSYS_NO_PATHCONV:-}" "${MSYS2_ARG_CONV_EXCL:-}" >>"$msys_log"
    printf ' <%s>' "$@" >>"$msys_log"
    printf '\n' >>"$msys_log"
    if [[ "${1:-}" == inspect && "${2:-}" == -f && "${3:-}" == '{{.State.Running}}' ]]; then
      printf '%s\n' true
    fi
  }
  # shellcheck source=lib/container-exec.sh
  source "$ROOT/lib/container-exec.sh"
  export MSYSTEM=MINGW64
  export OSTYPE=msys
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  _container_exec_argv cid-win --workdir '/app/path with spaces' -- printf '%s' '$(danger)'
)
assert_file_contains "$msys_log" 'env:1:* args: <exec> <--workdir> </app/path with spaces> <cid-win> <printf> <%s> <$(danger)>'
pass "Git Bash/MSYS disables Docker path conversion and preserves argv"

linux_log="$tmp/linux.log"
(
  set -euo pipefail
  err() { :; }
  docker() {
    printf 'env:%s:%s args:' "${MSYS_NO_PATHCONV:-}" "${MSYS2_ARG_CONV_EXCL:-}" >>"$linux_log"
    printf ' <%s>' "$@" >>"$linux_log"
    printf '\n' >>"$linux_log"
    if [[ "${1:-}" == inspect && "${2:-}" == -f && "${3:-}" == '{{.State.Running}}' ]]; then
      printf '%s\n' true
    fi
  }
  # shellcheck source=lib/container-exec.sh
  source "$ROOT/lib/container-exec.sh"
  unset MSYSTEM CYGWIN
  export OSTYPE=linux-gnu
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  _container_exec_argv cid-linux -- echo ok
)
assert_file_contains "$linux_log" 'env:: args: <exec> <cid-linux> <echo> <ok>'
pass "Linux/WSL path keeps native Docker argument behavior"

signal_log="$tmp/signal.log"
(
  set -euo pipefail
  err() { :; }
  docker() {
    if [[ "${1:-}" == inspect && "${2:-}" == -f && "${3:-}" == '{{.State.Running}}' ]]; then
      printf '%s\n' true
      return 0
    fi
    if [[ "${1:-}" == exec ]]; then
      return 130
    fi
    return 0
  }
  # shellcheck source=lib/container-exec.sh
  source "$ROOT/lib/container-exec.sh"
  unset MSYSTEM CYGWIN
  export OSTYPE=linux-gnu
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  set +e
  _container_exec_argv cid-signal -- signal-test
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$signal_log"
)
[[ "$(cat "$signal_log")" == 130 ]] || fail "container exec did not propagate exit 130"
pass "shared executor propagates SIGINT-style container exit status"

printf 'Container execution substrate contract complete.\n'
