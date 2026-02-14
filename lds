#!/usr/bin/env bash
# lds - LocalDevStack dispatcher (canonical: lib/ + bin/)
#
# Layout:
#   lds
#   lib/*.sh
#   bin/lds-*

set -euo pipefail

# Force bash even if invoked via sh
if [[ -z "${BASH_VERSION:-}" ]]; then exec /usr/bin/env bash "$0" "$@"; fi

# ------------------------------
# 0) Resolve project root (DIR)
# ------------------------------
_realpath() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then realpath "$p"; return 0; fi
  if readlink -f / >/dev/null 2>&1; then readlink -f "$p"; return 0; fi
  if command -v greadlink >/dev/null 2>&1; then greadlink -f "$p"; return 0; fi
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$p"; return 0; fi
  local d b
  d="$(cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
  b="$(basename -- "$p")"
  printf '%s/%s\n' "$d" "$b"
}

DIR="$(dirname -- "$(_realpath "$0")")"
export DIR
export LDS_ROOT="$DIR"
export CFG="$DIR/docker"
export ENV_MAIN="$DIR/.env"
export ENV_DOCKER="$DIR/docker/.env"
export COMPOSE_FILE="$DIR/docker/compose/main.yaml"
export EXTRAS_DIR="$DIR/docker/extras"

# Windows workdir hint (kept as-is for your wrappers)
if [[ "${1:-}" == "--__win_workdir" ]]; then
  export WORKDIR_WIN="${2:-}"
  shift 2
fi

# ------------------------------
# 1) Minimal error formatting + trap
# ------------------------------
_color() { printf '\033[%sm' "$1"; }
RED=$(_color '0;31')
YELLOW=$(_color '1;33')
NC=$(_color '0')

die() { printf "%bError:%b %s\n" "$RED" "$NC" "$*" >&2; exit 1; }

on_error() {
  local code="$1" line="$2" cmd="$3"
  printf "\n%bError:%b '%s' failed at line %d (exit %d)\n\n"     "$RED" "$NC" "$cmd" "$line" "$code" >&2
  exit "$code"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ------------------------------
# 2) Load bootstrap (helpers only; MUST NOT shift args)
# ------------------------------
if [[ -r "$DIR/lib/bootstrap.sh" ]]; then
  # shellcheck disable=SC1090
  source "$DIR/lib/bootstrap.sh"
fi

# ------------------------------
# 3) Global flags
# ------------------------------
VERBOSE="${VERBOSE:-0}"
QUIET="${QUIET:-0}"

while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; QUIET=0; shift ;;
    -q|--quiet)   QUIET=1; VERBOSE=0; shift ;;
    -h|--help)    set -- help "${@:2}" ;;
    --) shift; break ;;
    *) break ;;
  esac
done
export VERBOSE QUIET

# ------------------------------
# 4) Dispatch
# ------------------------------
cmd="${1:-help}"
shift || true

if [[ ! "$cmd" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  die "Invalid command: $cmd"
fi

: "${LDS_PROXY_TOOLS:=1}"
export LDS_PROXY_TOOLS

bin="$DIR/bin/lds-$cmd"
if [[ -x "$bin" ]]; then
  exec "$bin" "$@"
fi

# If command missing, show canonical help
if [[ -x "$DIR/bin/lds-help" ]]; then
  printf "%bWarning:%b unknown command '%s'\n\n" "$YELLOW" "$NC" "$cmd" >&2
  exec "$DIR/bin/lds-help"
fi

die "Unknown command '$cmd' (and bin/lds-help not found)"
