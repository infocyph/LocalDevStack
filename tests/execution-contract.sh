#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

die() {
  printf 'die:%s\n' "$*" >&2
  return 97
}

lds_project() { printf '%s' testproject; }
resolve_service() {
  case "${1:-}" in
    web|WEB) printf '%s' web ;;
    scaled) printf '%s' scaled ;;
    stopped) printf '%s' stopped ;;
    *) printf '%s' "${1:-}" ;;
  esac
}
compose_service_exists() {
  case "${1:-}" in web|scaled|stopped) return 0 ;; *) return 1 ;; esac
}

docker_compose() {
  case "$*" in
    "ps -a -q web") printf '%s\n' cid-web ;;
    "ps -a -q scaled") printf '%s\n' cid-a cid-b ;;
    "ps -a -q stopped") printf '%s\n' cid-stopped ;;
    *) return 1 ;;
  esac
}

DOCKER_LOG=''
DOCKER_HAS_BASH=1
DOCKER_FORCE_RC=0
DOCKER_MSYS_SEEN=''
docker() {
  if [[ "${1:-}" == inspect ]]; then
    shift
    if [[ "${1:-}" == -f ]]; then
      local fmt="$2" target="$3"
      case "$fmt|$target" in
        '{{.State.Running}}|cid-web'|'{{.State.Running}}|ExactCase') printf '%s\n' true ;;
        '{{.State.Running}}|cid-stopped') printf '%s\n' false ;;
        '{{.Id}}|ExactCase') printf '%s\n' exact-id ;;
        '{{.Name}}|cid-web') printf '%s\n' /testproject-web-1 ;;
        '{{.Name}}|ExactCase') printf '%s\n' /ExactCase ;;
        *) return 1 ;;
      esac
      return
    fi
    case "${1:-}" in ExactCase|cid-web|cid-stopped) return 0 ;; *) return 1 ;; esac
  fi

  if [[ "${1:-}" == exec ]]; then
    DOCKER_MSYS_SEEN="${MSYS_NO_PATHCONV:-}|${MSYS2_ARG_CONV_EXCL:-}"
    export DOCKER_MSYS_SEEN
    local serialized='' arg
    for arg in "$@"; do
      printf -v serialized '%s <%s>' "$serialized" "$arg"
    done
    DOCKER_LOG="$serialized"
    export DOCKER_LOG
    # Shell detection / workdir probes.
    if [[ "$*" == *" sh -c "* ]]; then
      if [[ "$*" == *'command -v bash'* ]]; then
        if ((DOCKER_HAS_BASH)); then printf '%s' bash; else printf '%s' sh; fi
        return 0
      fi
      if [[ "$*" == *'[ -d "$1" ]'* ]]; then
        local last_arg="${!#}"
        [[ "$last_arg" == /srv/app ]] && return 0
        return 1
      fi
      if [[ "$*" == *'[ -d /app ]'* ]]; then return 0; fi
    fi
    ((DOCKER_FORCE_RC == 0)) || return "$DOCKER_FORCE_RC"
    return 0
  fi
  return 0
}

# shellcheck source=lib/execution.sh
source "$ROOT/lib/execution.sh"

_container_resolve_target web
[[ "$LDS_CONTAINER_KIND" == service ]] || fail "service target kind not resolved"
[[ "$LDS_CONTAINER_ID" == cid-web ]] || fail "service target id drifted"
[[ "$LDS_CONTAINER_SERVICE" == web ]] || fail "service target name drifted"
pass "service-first container resolution"

_container_resolve_target ExactCase
[[ "$LDS_CONTAINER_KIND" == container ]] || fail "exact container target not preserved"
[[ "$LDS_CONTAINER_NAME" == ExactCase ]] || fail "explicit container case was changed"
[[ "$LDS_CONTAINER_ID" == exact-id ]] || fail "explicit container id not canonicalized"
pass "exact container fallback preserves case"

set +e
_container_resolve_target scaled
rc=$?
set -e
[[ "$rc" -eq 65 && "$LDS_CONTAINER_ERROR" == ambiguous ]] ||
  fail "scaled service did not report ambiguity"
set +e
_container_resolve_target stopped
rc=$?
set -e
[[ "$rc" -eq 69 && "$LDS_CONTAINER_ERROR" == stopped ]] ||
  fail "stopped service did not report stopped state"
set +e
_container_resolve_target missing
rc=$?
set -e
[[ "$rc" -eq 67 && "$LDS_CONTAINER_ERROR" == missing ]] ||
  fail "missing target did not report missing state"
pass "resolver distinguishes ambiguous stopped and missing targets"

_container_stdin_is_tty() { return 1; }
_container_stdout_is_tty() { return 1; }
_container_exec_flags command
[[ "${#LDS_CONTAINER_EXEC_FLAGS[@]}" -eq 0 ]] || fail "non-interactive command allocated exec flags"

_container_stdin_is_tty() { return 0; }
_container_stdout_is_tty() { return 1; }
_container_exec_flags command
[[ "${LDS_CONTAINER_EXEC_FLAGS[*]}" == "-i" ]] || fail "piped stdin did not preserve -i without -t"

_container_stdin_is_tty() { return 0; }
_container_stdout_is_tty() { return 0; }
_container_exec_flags command
[[ "${LDS_CONTAINER_EXEC_FLAGS[*]}" == "-i -t" ]] || fail "interactive command did not allocate -it"
pass "TTY flags adapt to actual stdin/stdout"

DOCKER_LOG=''
_container_exec_argv cid-web /srv/app printf '%s\n' 'hello world' '$(touch /tmp/nope)' 'a;b'
[[ "$DOCKER_LOG" == *'<-w> </srv/app> <cid-web> <printf> <%s\n> <hello world> <$(touch /tmp/nope)> <a;b>'* ]] ||
  fail "command argv was flattened or reinterpreted: $DOCKER_LOG"
pass "explicit command argv stays literal"

DOCKER_LOG=''
_container_exec_argv cid-web '/srv/My App' printf '%s' 'spaced value'
[[ "$DOCKER_LOG" == *'<-w> </srv/My App> <cid-web> <printf> <%s> <spaced value>'* ]] ||
  fail "working directory with spaces was not preserved: $DOCKER_LOG"

MSYSTEM=MINGW64
DOCKER_MSYS_SEEN=''
_container_exec_argv cid-web '/app' true
unset MSYSTEM
[[ "$DOCKER_MSYS_SEEN" == '1|*' ]] ||
  fail "Git Bash docker path-conversion guard was not applied"
pass "paths with spaces and Git Bash path conversion are protected"

DOCKER_FORCE_RC=42
set +e
_container_exec_argv cid-web '' child-command
rc=$?
set -e
DOCKER_FORCE_RC=0
[[ "$rc" -eq 42 ]] || fail "child exit status did not propagate"
pass "child command exit status propagates"

_container_stdin_is_tty() { return 1; }
_container_stdout_is_tty() { return 1; }
set +e
(
  die() { exit 97; }
  _container_open_shell cid-web '' >/dev/null 2>&1
)
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "interactive shell unexpectedly ran without a TTY"
pass "interactive shell rejects non-TTY invocation"

DOCKER_HAS_BASH=0
[[ "$(_container_shell_path cid-web)" == sh ]] || fail "Bash-unavailable container did not fall back to sh"
DOCKER_HAS_BASH=1
[[ "$(_container_shell_path cid-web)" == bash ]] || fail "Bash-capable container did not prefer bash"
pass "interactive shell resolver prefers Bash and falls back to sh"

[[ "$(_container_existing_workdir cid-web /srv/app)" == /srv/app ]] ||
  fail "existing preferred workdir was not preserved"
[[ "$(_container_existing_workdir cid-web /missing)" == /app ]] ||
  fail "missing preferred workdir did not fall back to /app"
pass "working-directory fallback is deterministic"

# Domain metadata is centralized behind one helper.
_project_tools_container_running() { printf '%s' tools-id; }
docker() {
  if [[ "${1:-}" == exec && "${2:-}" == tools-id && "${3:-}" == domain-which ]]; then
    case "${4:-}" in
      --app) printf '%s\n' node ;;
      --container) printf '%s\n' ExactCase ;;
      --docroot) printf '%s\n' /srv/site ;;
      --list-domains) printf '%s\n' z.localhost a.localhost a.localhost ;;
    esac
    return 0
  fi
  if [[ "${1:-}" == inspect ]]; then
    shift
    if [[ "${1:-}" == -f ]]; then
      case "$2|$3" in
        '{{.State.Running}}|ExactCase') printf '%s\n' true ;;
        '{{.Id}}|ExactCase') printf '%s\n' exact-id ;;
        '{{.Name}}|ExactCase') printf '%s\n' /ExactCase ;;
        *) return 1 ;;
      esac
      return
    fi
    [[ "${1:-}" == ExactCase ]] && return 0
  fi
  if [[ "${1:-}" == exec && "${2:-}" == exact-id && "${3:-}" == sh && "${4:-}" == -c ]]; then
    [[ "${*:5}" == *'[ -d "$1" ]'* ]] && return 1
    [[ "${*:5}" == *'[ -d /app ]'* ]] && return 0
  fi
  return 0
}
mapfile -t domains < <(_core_domain_list)
[[ "${domains[*]}" == "a.localhost z.localhost" ]] || fail "domain list is not stable/unique"
_core_domain_resolve example.localhost
[[ "$LDS_CORE_APP" == node ]] || fail "domain app type missing"
[[ "$LDS_CORE_CONTAINER" == exact-id ]] || fail "domain container was not canonicalized"
[[ "$LDS_CORE_WORKDIR" == /app ]] || fail "Node domain did not force /app"
pass "domain discovery and metadata resolution are centralized"

assert_file_contains "$ROOT/lib/services.sh" '_container_exec_argv'
assert_file_contains "$ROOT/lib/services.sh" '_container_open_shell'
assert_file_contains "$ROOT/lib/services.sh" '_core_domain_resolve'
if grep -q 'local cmd="$\*"' "$ROOT/lib/services.sh"; then
  fail "services execution still flattens normal command argv"
fi
if grep -q "tr '[:lower:]' '[:upper:]'" "$ROOT/lib/services.sh"; then
  fail "core still uppercases raw container targets"
fi
pass "user-facing execution surfaces delegate to shared substrate"
