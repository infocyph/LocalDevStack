# lds lib: bootstrap
# shellcheck shell=bash

# Expect DIR/CFG/ENV_MAIN/ENV_DOCKER/COMPOSE_FILE/EXTRAS_DIR set by caller.

# Default behavior: QUIET
: "${VERBOSE:=0}"

COLOR() { printf '\033[%sm' "$1"; }

# Color helpers/vars (only if not already set)
if [[ -z "${RED:-}" ]]; then
  RED=$(COLOR '0;31'); GREEN=$(COLOR '0;32'); CYAN=$(COLOR '0;36')
  YELLOW=$(COLOR '1;33'); BLUE=$(COLOR '0;34'); MAGENTA=$(COLOR '0;35')
  NC=$(COLOR '0')
fi

_realpath() {
  local p="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
    return 0
  fi

  # GNU readlink
  if readlink -f / >/dev/null 2>&1; then
    readlink -f "$p"
    return 0
  fi

  # macOS with coreutils
  if command -v greadlink >/dev/null 2>&1; then
    greadlink -f "$p"
    return 0
  fi

  # python fallback
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$p"
    return 0
  fi

  # last resort: absolute physical dir + basename
  local d b
  d="$(cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
  b="$(basename -- "$p")"
  printf '%s/%s\n' "$d" "$b"
}

on_error() {
  printf "\n%bError:%b '%s' failed at line %d (exit %d)\n\n" \
    "$RED" "$NC" "$3" "$2" "$1"
  exit "$1"
}
die() {
  printf "%bError:%b %s\n" "$RED" "$NC" "$*"
  exit 1
}
need() {
  local group found cmd
  for group in "$@"; do
    IFS='|,' read -ra alts <<<"$group"
    found=0
    for cmd in "${alts[@]}"; do
      command -v "$cmd" &>/dev/null && {
        found=1
        break
      }
    done
    ((found)) && continue
    local miss=${alts[*]}
    miss=${miss// / or }
    die "Missing command(s): $miss"
  done
}
ensure_files_exist() {
  local rel abs dir
  for rel in "$@"; do
    abs="${DIR}${rel}"
    dir="${abs%/*}"

    if [[ ! -d $dir ]]; then
      if mkdir -p "$dir" 2>/dev/null; then
        printf "%b- Created directory %s%b\n" "$YELLOW" "$dir" "$NC"
      else
        printf "%b- Warning:%b cannot create directory %s (permissions?)\n" \
          "$YELLOW" "$NC" "$dir"
        continue
      fi
    elif [[ ! -w $dir ]]; then
      printf "%b- Warning:%b directory not writable: %s\n" "$YELLOW" "$NC" "$dir"
    fi

    if [[ -e $abs ]]; then
      [[ -w $abs ]] || printf "%b- Warning:%b file not writable: %s\n" "$YELLOW" "$NC" "$abs"
    else
      if : >"$abs" 2>/dev/null; then
        printf "%b- Created file %s%b\n" "$YELLOW" "$abs" "$NC"
      else
        printf "%b- Error:%b cannot create file %s (permissions?)\n" "$RED" "$NC" "$abs"
      fi
    fi
  done
}
logv() { ((VERBOSE)) && printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2 || true; }
logq() { printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2; }
tty_readline() {
  # Robust prompt/read across Linux/macOS/WSL/Windows Git Bash.
  # Prefer stdin when it is a TTY (normal interactive use). If stdin is not a TTY,
  # fall back to /dev/tty when available.
  local __var_name="$1" __prompt="$2" __line

  if [[ -t 0 ]]; then
    # Interactive: show prompt on stderr (so it is never swallowed) and read stdin.
    printf '%s' "$__prompt" >&2
    IFS= read -r __line || return 1
  elif [[ -r /dev/tty ]]; then
    # Non-interactive stdin (piped) but we still have a controlling terminal.
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

