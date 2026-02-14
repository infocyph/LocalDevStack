#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/bootstrap.sh — foundational helpers (NO arg parsing, NO shifting)
#
# This file may be sourced by:
#   - ./lds (dispatcher)  [DIR already exported]
#   - ./bin/lds-*         [often sets ROOT or LDS_ROOT]
#
# Rules:
#   - Never shift arguments or parse flags here
#   - Never assume $0 is project root
#   - Only set DIR/paths if they are missing, and never override if present

set -euo pipefail

# ------------------------------
# 0) Root resolution (only if needed)
# ------------------------------
if [[ -z "${DIR:-}" ]]; then
  if [[ -n "${LDS_ROOT:-}" ]]; then
    DIR="$LDS_ROOT"
  elif [[ -n "${ROOT:-}" ]]; then
    DIR="$ROOT"
  else
    DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  export DIR
fi

# Derived paths (do not override if already provided by dispatcher)
: "${CFG:="$DIR/docker"}"
: "${ENV_MAIN:="$DIR/.env"}"
: "${ENV_DOCKER:="$CFG/.env"}"
: "${COMPOSE_FILE:="$CFG/compose/main.yaml"}"
: "${EXTRAS_DIR:="$CFG/extras"}"
export CFG ENV_MAIN ENV_DOCKER COMPOSE_FILE EXTRAS_DIR

# Windows workdir hint is handled by dispatcher; bin scripts may still export it.
: "${WORKDIR_WIN:=${WORKDIR_WIN:-}}"
export WORKDIR_WIN

# ------------------------------
# 1) Colors / logging defaults
# ------------------------------
COLOR() { printf '\033[%sm' "$1"; }
RED=$(COLOR '0;31'); GREEN=$(COLOR '0;32'); CYAN=$(COLOR '0;36')
YELLOW=$(COLOR '1;33'); BLUE=$(COLOR '0;34'); MAGENTA=$(COLOR '0;35')
NC=$(COLOR '0')

: "${VERBOSE:=0}"
: "${QUIET:=0}"
export VERBOSE QUIET

lds_colors_init() {
  COLOR() { printf '\033[%sm' "$1"; }  # shadow-safe
  RED=$(COLOR '0;31'); GREEN=$(COLOR '0;32'); CYAN=$(COLOR '0;36')
  YELLOW=$(COLOR '1;33'); BLUE=$(COLOR '0;34'); MAGENTA=$(COLOR '0;35')
  NC=$(COLOR '0')
}

logv() { ((VERBOSE)) && printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2 || true; }
logq() { ((QUIET)) && return 0; printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2; }

# ------------------------------
# 2) Error helpers (trap owned by dispatcher; safe standalone usage too)
# ------------------------------
die() {
  printf "%bError:%b %s\n" "$RED" "$NC" "$*" >&2
  exit 1
}

need() {
  local group found cmd
  for group in "$@"; do
    IFS='|,' read -ra alts <<<"$group"
    found=0
    for cmd in "${alts[@]}"; do
      command -v "$cmd" &>/dev/null && { found=1; break; }
    done
    ((found)) && continue
    local miss=${alts[*]}
    miss=${miss// / or }
    die "Missing command(s): $miss"
  done
}

# ------------------------------
# 3) FS helpers
# ------------------------------
ensure_files_exist() {
  local rel abs dir
  for rel in "$@"; do
    abs="${DIR}${rel}"
    dir="${abs%/*}"

    if [[ ! -d $dir ]]; then
      if mkdir -p "$dir" 2>/dev/null; then
        logq warn "Created directory $dir"
      else
        logq warn "Cannot create directory $dir (permissions?)"
        continue
      fi
    elif [[ ! -w $dir ]]; then
      logq warn "Directory not writable: $dir"
    fi

    if [[ -e $abs ]]; then
      [[ -w $abs ]] || logq warn "File not writable: $abs"
    else
      if : >"$abs" 2>/dev/null; then
        logq warn "Created file $abs"
      else
        logq warn "Cannot create file $abs (permissions?)"
      fi
    fi
  done
}

# ------------------------------
# 4) Prompt helpers (used by setup/menu flows)
# ------------------------------
tty_readline() {
  local __var_name="$1" __prompt="$2" __line

  if [[ -t 0 ]]; then
    printf '%s' "$__prompt" >&2
    IFS= read -r __line || return 1
  elif [[ -r /dev/tty ]]; then
    printf '%s' "$__prompt" >/dev/tty
    IFS= read -r __line </dev/tty || return 1
  else
    return 1
  fi

  printf -v "$__var_name" '%s' "$__line"
}

read_default() {
  local prompt=$1 default=$2 input
  tty_readline input "$(printf '%b%s [default: %s]:%b ' "$CYAN" "$prompt" "$default" "$NC")" || return 1
  printf '%s' "${input:-$default}"
}

ask_yes() {
  local prompt="$1" ans
  tty_readline ans "$(printf '%b%s (y/n): %b' "$BLUE" "$prompt" "$NC")" || return 1
  [[ "${ans,,}" == "y" ]]
}

is_windows_shell() {
  [[ "${OSTYPE:-}" =~ (msys|cygwin) ]] || [[ -n "${WORKDIR_WIN:-}" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Tool proxy (enabled only when LDS_PROXY_TOOLS=1)
# ─────────────────────────────────────────────────────────────────────────────
lds_tools_cmd() {
  local cmd="${1:-}"
  shift || true
  [[ -n "$cmd" ]] || { echo "lds_tools_cmd: missing command" >&2; return 2; }

  local -a flags=()
  [[ -t 0 ]] && flags+=(-i)
  [[ -t 1 ]] && flags+=(-t)

  # if command exists on host
  if command -v "$cmd" >/dev/null 2>&1; then
    command "$cmd" "$@"
    return $?
  fi

  # If SERVER_TOOLS is running
  if docker inspect -f '{{.State.Running}}' SERVER_TOOLS 2>/dev/null | grep -qx true; then
    if docker exec "${flags[@]}" SERVER_TOOLS "$cmd" "$@"; then
      return 0
    fi
  fi

  echo "Error: '$cmd' not available (SERVER_TOOLS not running and host command missing)" >&2
  return 127
}

if ((${LDS_PROXY_TOOLS:-0})); then
  jq() { lds_tools_cmd jq "$@"; }
  yq() { lds_tools_cmd yq "$@"; }
  rg() { lds_tools_cmd rg "$@"; }
  fd() { lds_tools_cmd fd "$@"; }
  shellcheck() { lds_tools_cmd shellcheck "$@"; }
  tree() { lds_tools_cmd tree "$@"; }
fi
