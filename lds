#!/usr/bin/env bash
# Force bash even if invoked via sh
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

# shellcheck disable=SC1090,SC2155

set -euo pipefail

###############################################################################
# 0. CORE / BOOTSTRAP-SAFE HELPERS (no Docker required)
###############################################################################

# Color defaults (overridden later by init_colors); keep safe under set -u
BOLD="${BOLD:-}"
DIM="${DIM:-}"
RED="${RED:-}"
GREEN="${GREEN:-}"
CYAN="${CYAN:-}"
YELLOW="${YELLOW:-}"
BLUE="${BLUE:-}"
MAGENTA="${MAGENTA:-}"
NC="${NC:-}"

die() {
  printf "%bError:%b %s
" "${RED:-}" "${NC:-}" "$*" >&2
  exit 1
}

###############################################################################
# Command presence + tool proxy rules
# - Host-only commands MUST exist on host (e.g. docker)
# - Proxy-safe tools may run from the project tools container when LDS_PROXY_TOOLS=1 and container is up
# - Anything inside `docker exec ... sh -lc '...'` must continue to use `command -v`
###############################################################################

# Cached executable lookup (host binaries only; ignores shell functions/aliases)
declare -A __LDS_HAS_BIN=()

# Back-compat: treat has_cmd as 'host binary exists' (functions/aliases do not count).
has_cmd() { has_bin "$@"; }

has_bin() {
  local c="${1:-}"
  [[ -n "$c" ]] || return 1
  if [[ -n "${__LDS_HAS_BIN[$c]+x}" ]]; then
    return "${__LDS_HAS_BIN[$c]}"
  fi
  type -P -- "$c" >/dev/null 2>&1
  __LDS_HAS_BIN[$c]=$?
  return "${__LDS_HAS_BIN[$c]}"
}

bin_path() { type -P -- "${1:?}"; }

need_bin() {
  local c="${1:-}" hint="${2:-}"
  has_bin "$c" && return 0
  die "Missing required command: $c${hint:+ ($hint)}"
}

# Commands that must NEVER be proxied to project tools container (host control plane / privileged / filesystem)
_is_host_only_cmd() {
  case "${1:-}" in
  docker | sudo | su | systemctl | service | ip | iptables | nft | sysctl | mount | umount | modprobe | insmod | rmmod | rm | mv | cp | chmod | chown)
    return 0
    ;;
  esac
  return 1
}

# Resolve the project-specific tools container name.
_project_tools_container() {
  has_bin docker || return 1

  local project ctr
  project="$(lds_project)"

  ctr="$(
    docker ps -a \
      --filter "label=com.docker.compose.project=$project" \
      --filter 'label=com.docker.compose.service=server-tools' \
      --format '{{.Names}}' 2>/dev/null | sed -n '1p'
  )"
  [[ -n "$ctr" ]] && {
    printf '%s' "$ctr"
    return 0
  }

  ctr="$(docker_compose ps -a server-tools --format '{{.Name}}' 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$ctr" ]] && {
    printf '%s' "$ctr"
    return 0
  }

  return 1
}

_project_tools_container_running() {
  local ctr
  ctr="$(_project_tools_container || true)"
  [[ -n "$ctr" ]] || return 1
  docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -qx true || return 1
  printf '%s' "$ctr"
}

_server_tools_running() {
  [[ -n "$(_project_tools_container_running || true)" ]]
}

_server_tools_has() {
  local c="${1:-}"
  [[ -n "$c" ]] || return 1
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || return 1
  "$(bin_path docker)" exec "$ctr" sh -lc "command -v \"$c\" >/dev/null 2>&1" >/dev/null 2>&1
}

# Unified command runner for proxy-safe tools
# Resolution order (your rule-set):
# 1) if cmd exists on host -> run host binary
# 2) if host-only and missing -> error
# 3) if proxy-safe and LDS_PROXY_TOOLS=1 and project tools up and cmd exists there -> run via docker exec
# 4) otherwise -> error
lds_tools_cmd() {
  local cmd="${1:-}"
  shift || true
  [[ -n "$cmd" ]] || {
    echo "lds_tools_cmd: missing command" >&2
    return 2
  }

  # 1) host binary wins
  if has_bin "$cmd"; then
    local p
    p="$(bin_path "$cmd")"
    "$p" "$@"
    return $?
  fi

  # 2) host-only commands must be present on host
  if _is_host_only_cmd "$cmd"; then
    echo "Error: '$cmd' is required on host but was not found" >&2
    return 127
  fi

  # 3) proxy-safe tools from project tools container (opt-in)
  if ((${LDS_PROXY_TOOLS:-1})); then
    if ! has_bin docker; then
      echo "Error: '$cmd' not available on host; tool proxy requires host 'docker'" >&2
      return 127
    fi
    local ctr
    ctr="$(_project_tools_container_running || true)"
    if [[ -z "$ctr" ]]; then
      echo "Error: '$cmd' not available on host and project tools container is not running (set LDS_PROXY_TOOLS=1 and start the stack)" >&2
      return 127
    fi
    if ! _server_tools_has "$cmd"; then
      echo "Error: '$cmd' not found on host nor inside project tools container" >&2
      return 127
    fi

    local -a flags=()
    [[ -t 0 ]] && flags+=(-i)
    [[ -t 1 ]] && flags+=(-t)
    "$(bin_path docker)" exec "${flags[@]}" "$ctr" "$cmd" "$@"
    return $?
  fi

  # 4) not found and proxy not enabled
  echo "Error: '$cmd' not available on host (set LDS_PROXY_TOOLS=1 to proxy via project tools container)" >&2
  return 127
}

# Convenience wrappers for common proxy-safe tools
jq() { lds_tools_cmd jq "$@"; }
yq() { lds_tools_cmd yq "$@"; }
rg() { lds_tools_cmd rg "$@"; }
fd() { lds_tools_cmd fd "$@"; }
tree() { lds_tools_cmd tree "$@"; }
shellcheck() { lds_tools_cmd shellcheck "$@"; }

# Tool availability checks (host binary OR proxy-available)
has_tool() {
  local c="${1:-}"
  has_bin "$c" && return 0
  _is_host_only_cmd "$c" && return 1
  ((${LDS_PROXY_TOOLS:-1})) || return 1
  _server_tools_has "$c"
}

need_tool() {
  local c="${1:-}" hint="${2:-}"
  has_tool "$c" && return 0
  die "Missing required command: $c${hint:+ ($hint)}"
}

###############################################################################
# Misc helpers used across the script
###############################################################################

need() {
  local group found cmd
  for group in "$@"; do
    IFS='|,' read -ra alts <<<"$group"
    found=0
    for cmd in "${alts[@]}"; do
      has_bin "$cmd" && {
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

# Stream search helper: prefers ripgrep (rg) when available (host or proxied), falls back to grep.
# Reads from stdin, prints matching lines with line numbers.
text_grep() {
  local ins=0
  if [[ "${1:-}" == "-i" ]]; then
    ins=1
    shift || true
  fi

  local pat="${1:-}"
  [[ -n "$pat" ]] || return 0

  if has_tool rg; then
    if ((ins)); then rg -n -i -- "$pat"; else rg -n -- "$pat"; fi
  else
    if ((ins)); then grep -ni -- "$pat"; else grep -n -- "$pat"; fi
  fi
}

ensure_files_exist() {
  local rel abs dir
  for rel in "$@"; do
    abs="${DIR}${rel}"
    dir="${abs%/*}"

    if [[ ! -d $dir ]]; then
      if mkdir -p "$dir" 2>/dev/null; then
        printf "%b- Created directory %s%b\n" "${YELLOW:-}" "$dir" "${NC:-}"
      else
        printf "%b- Warning:%b cannot create directory %s (permissions?)\n" \
          "${YELLOW:-}" "${NC:-}" "$dir"
        continue
      fi
    elif [[ ! -w $dir ]]; then
      printf "%b- Warning:%b directory not writable: %s\n" "${YELLOW:-}" "${NC:-}" "$dir"
    fi

    if [[ -e $abs ]]; then
      [[ -w $abs ]] || printf "%b- Warning:%b file not writable: %s\n" "${YELLOW:-}" "${NC:-}" "$abs"
    else
      if : >"$abs" 2>/dev/null; then
        printf "%b- Created file %s%b\n" "${YELLOW:-}" "$abs" "${NC:-}"
      else
        printf "%b- Error:%b cannot create file %s (permissions?)\n" "${RED:-}" "${NC:-}" "$abs"
      fi
    fi
  done
}

###############################################################################
# 0. BOOTSTRAP / PATHS / CONSTANTS
###############################################################################
# Resolve script directory portably (Linux/macOS/WSL)
_realpath() {
  local p="$1"

  if has_cmd realpath; then
    realpath "$p"
    return 0
  fi

  # GNU readlink
  if readlink -f / >/dev/null 2>&1; then
    readlink -f "$p"
    return 0
  fi

  # macOS with coreutils
  if has_cmd greadlink; then
    greadlink -f "$p"
    return 0
  fi

  # last resort: absolute physical dir + basename
  local d b
  d="$(cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
  b="$(basename -- "$p")"
  printf '%s/%s\n' "$d" "$b"
}

DIR="$(dirname -- "$(_realpath "$0")")"
CFG="$DIR/docker"
ENV_MAIN="$DIR/.env"
ENV_DOCKER="$CFG/.env"
ENV_RELEASE="$CFG/release.env"
COMPOSE_FILE="$CFG/compose/main.yaml"
EXTRAS_DIR="$DIR/configuration/compose"

# Read a literal dotenv KEY=VALUE without sourcing/evaluating the file.
dotenv_value() {
  local file="${1:-}" key="${2:-}" line value first last
  [[ -r "$file" && -n "$key" ]] || return 1

  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"

  if (("${#value}" >= 2)); then
    first="${value:0:1}"
    last="${value: -1}"
    if [[ "$first" == '"' && "$last" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$first" == "'" && "$last" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "$value"
}

# Control-state precedence: shell > user docker/.env > release.env > fallback.
compose_control_value() {
  local key="${1:?}" fallback="${2-}" value
  if [[ -v "$key" ]]; then
    printf '%s' "${!key}"
    return 0
  fi
  if value="$(dotenv_value "$ENV_DOCKER" "$key")"; then
    printf '%s' "$value"
    return 0
  fi
  if value="$(dotenv_value "$ENV_RELEASE" "$key")"; then
    printf '%s' "$value"
    return 0
  fi
  printf '%s' "$fallback"
}

if [[ "${1:-}" == "--__win_workdir" ]]; then
  export WORKDIR_WIN="${2:-}"
  shift 2
fi

COLOR() { printf '[%sm' "$1"; }
###############################################################################
# Colors + UI (higher contrast; aligned with mkhost.sh)
###############################################################################
# Color control:
# - If stdout isn't a TTY, disable colors by default.
# - If NO_COLOR is set, disable colors.
# - Set LDS_FORCE_COLOR=1 to force colors.
_is_tty() { [[ -t 1 ]]; }

_use_color=1
if [[ "${LDS_FORCE_COLOR:-0}" != "1" ]]; then
  if [[ -n "${NO_COLOR:-}" ]] || ! _is_tty; then
    _use_color=0
  fi
fi

if ((_use_color)); then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[1;31m'
  GREEN=$'\033[1;32m'
  CYAN=$'\033[1;36m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[1;34m'
  MAGENTA=$'\033[1;35m'
  NC=$'\033[0m'
else
  BOLD='' DIM='' RED='' GREEN='' CYAN='' YELLOW='' BLUE='' MAGENTA='' NC=''
fi

# Output control:
# - --quiet suppresses non-error output
QUIET=0

say() { ((QUIET)) || printf '%b\n' "$*"; }
ok() { ((QUIET)) || printf '%b\n' "${GREEN}$*${NC}"; }
warn() { ((QUIET)) || printf '%b\n' "${YELLOW}$*${NC}"; }
err() { printf '%b\n' "${RED}$*${NC}" >&2; }

# Default behavior: QUIET
VERBOSE=0

#───────────────────────────────────────────────────────────────────────────────
# 0a. GLOBAL ERROR HANDLER
#───────────────────────────────────────────────────────────────────────────────
command_not_found_handle() {
  local unknown="$1"
  [[ $unknown == cmd_* ]] && unknown=${unknown#cmd_}
  printf "\n%bError:%b Unknown command '%b'\n\n" "$RED" "$NC" "$unknown"
  cmd_help
  exit 1
}

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
on_error() {
  local code="$1" line="$2" cmd="$3"
  local fn="${FUNCNAME[1]:-main}"
  local src="${BASH_SOURCE[1]:-$0}"

  printf "\n%bError:%b %s:%s in %s() (exit %d)\n" "$RED" "$NC" "$src" "$line" "$fn" "$code" >&2
  printf "%bCommand:%b %s\n" "$RED" "$NC" "$cmd" >&2

  if ((VERBOSE)); then
    printf "%bStack:%b\n" "$DIM" "$NC" >&2
    local i=1
    while caller "$i" >/dev/null 2>&1; do
      caller "$i" >&2
      i=$((i + 1))
    done
  fi
  printf "\n" >&2
  exit "$code"
}

###############################################################################
# 1a. DOCKER COMPOSE WRAPPER
###############################################################################
# shellcheck source=lib/compose.sh
source "$DIR/lib/compose.sh"

###############################################################################
# 1b. PROMPTS + DOTENV HELPERS
###############################################################################
# shellcheck source=lib/env.sh
source "$DIR/lib/env.sh"

###############################################################################
# 1c. HTTP / WEB SERVER HELPERS
###############################################################################
# shellcheck source=lib/hosts.sh
source "$DIR/lib/hosts.sh"

###############################################################################
# 2. INSTALL / PERMISSIONS (HOST)
###############################################################################
# shellcheck source=lib/platform.sh
source "$DIR/lib/platform.sh"

###############################################################################
# 3. DOMAIN / PROFILE INTEGRATION
###############################################################################
# Host/domain functions are loaded by lib/hosts.sh above.

# ─────────────────────────────────────────────────────────────────────────────
# Profiles
# ─────────────────────────────────────────────────────────────────────────────

###############################################################################
# 3a. PROFILES: DEFINITIONS + SETUP FLOW
###############################################################################
# shellcheck source=lib/profiles.sh
source "$DIR/lib/profiles.sh"

###############################################################################
# 5. ENVIRONMENT + CERT / CA
###############################################################################
# shellcheck source=lib/certificates.sh
source "$DIR/lib/certificates.sh"

###############################################################################
# SERVICE / STACK OPERATIONS
###############################################################################
# shellcheck source=lib/services.sh
source "$DIR/lib/services.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 6d. DIAG / SNIFF
# ─────────────────────────────────────────────────────────────────────────────
# shellcheck source=lib/ai.sh
source "$DIR/lib/ai.sh"
# shellcheck source=lib/diagnostics.sh
source "$DIR/lib/diagnostics.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 6e/6f. SERVICE / HOST / MAINTENANCE COMMANDS
# ─────────────────────────────────────────────────────────────────────────────
# Implementations are loaded by lib/services.sh above.

# ─────────────────────────────────────────────────────────────────────────────
# 6g. HELP MARKDOWN
# ─────────────────────────────────────────────────────────────────────────────

# Service/rebuild/core/notify implementations are loaded by lib/services.sh.

###############################################################################
# RUN (ad-hoc Dockerfile runner)
###############################################################################
hash_short() {
  local s="$1"
  if has_cmd sha1sum; then
    printf '%s' "$s" | sha1sum | cut -c1-8
  elif has_cmd shasum; then
    printf '%s' "$s" | shasum -a 1 | cut -c1-8
  else
    # POSIX fallback; stable (not cryptographic)
    printf '%s' "$s" | cksum | awk '{print $1}'
  fi
}

run_slug() {
  local dir="$1" base hash
  base="$(basename "$dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
  hash="$(hash_short "$dir")"
  printf '%s-%s' "$base" "$hash"
}

run_plan() {
  local dir="$1" slug
  slug="$(run_slug "$dir")"
  printf '%s|%s|%s\n' \
    "lds-run-${slug}" \
    "${slug}:local" \
    "$dir"
}

detect_host_os() {
  if is_windows_shell || grep -qi microsoft /proc/version 2>/dev/null; then
    printf 'windows'
    return 0
  fi

  if has_cmd uname; then
    case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      printf 'macos'
      ;;
    Linux)
      printf 'linux'
      ;;
    *)
      printf 'unknown'
      ;;
    esac
  else
    printf 'unknown'
  fi
}

run_find_container() {
  local dir="$1"
  docker ps -a --filter "label=com.infocyph.lds.run=1" \
    --filter "label=com.infocyph.lds.dir=${dir}" \
    --format '{{.Names}}' | head -n 1
}

run_build() {
  local tag="$1" dir="$2"

  # Build only if the image doesn't already exist.
  if docker image inspect "$tag" >/dev/null 2>&1; then
    printf "%b[run]%b Image exists, skipping build: %b%s%b
" "$CYAN" "$NC" "$BLUE" "$tag" "$NC"
    return 0
  fi

  printf "%b[run]%b Building image %b%s%b from %s
" "$CYAN" "$NC" "$BLUE" "$tag" "$NC" "$dir"
  docker build -t "$tag" "$dir"
}

run_start() {
  local name="$1" tag="$2" dir="$3" keepalive="$4" sock="$5" host_os="$6"
  shift 6 || true

  # Remaining args are split by a "--" sentinel:
  #   - before "--" : publish specs (HOST:CONT), repeatable
  #   - after "--"  : mount specs (HOST[:CONT]), repeatable
  local -a pubs=() mounts=()
  local seen_delim=0 x
  for x in "$@"; do
    if [[ "$x" == "--" ]]; then
      seen_delim=1
      continue
    fi
    if ((seen_delim)); then
      mounts+=("$x")
    else
      pubs+=("$x")
    fi
  done

  # Normalize project dir (POSIX absolute).
  # On Windows Git Bash, /e/... is OK; docker.exe will receive converted path automatically.
  local dir_posix
  dir_posix="$(cd "$dir" 2>/dev/null && pwd -P)" || die "invalid dir: $dir"

  # MSYS-safe container paths: use '//' prefix to prevent path conversion.
  # Docker interprets //path as /path inside container.
  local WDIR="//workspace"
  local WDIR_MOUNT="${dir_posix}://workspace"

  local -a args=(docker run -d --name "$name"
    --label "com.infocyph.lds.run=1"
    --label "com.infocyph.lds.dir=$dir_posix"
    --label "com.infocyph.lds.tag=$tag"
    -w "$WDIR"
    -v "$WDIR_MOUNT"
  )

  if [[ -n "$host_os" ]]; then
    args+=(-e "HOST_OS=$host_os")
  fi

  # Mount extra directories/files (HOST[:CONT]).
  # - If container path missing, mounts under /mnt/<basename>.
  # - HOST may be relative to the run directory.
  if ((${#mounts[@]})); then
    local spec host cont base
    for spec in "${mounts[@]}"; do
      [[ -n "$spec" ]] || continue
      host="$spec"
      cont=""

      # Split as HOST:CONT ONLY if suffix after last ':' looks like a container absolute path (/...)
      # (safe for Windows drive letters like E:\... because tail won't start with '/')
      if [[ "$spec" == *:* ]]; then
        local tail="${spec##*:}"
        if [[ "$tail" == /* ]]; then
          host="${spec%:*}"
          cont="$tail"
        fi
      fi

      # Resolve host to absolute (POSIX) for checks
      if [[ "$host" != /* && "$host" != ~* && ! "$host" =~ ^[A-Za-z]:[\\/].* ]]; then
        host="${dir_posix%/}/$host"
      fi

      # If user provided Windows path (E:\...), convert to POSIX for existence check
      if [[ "$host" =~ ^[A-Za-z]:[\\/].* ]] && has_cmd cygpath; then
        host="$(cygpath -u "$host")"
      fi

      host="$(cd "${host%/*}" 2>/dev/null && pwd -P)/${host##*/}" || {
        printf "%b[run]%b Warning: cannot resolve mount path: %s\n" "$YELLOW" "$NC" "$spec" >&2
        continue
      }

      [[ -e "$host" ]] || {
        printf "%b[run]%b Warning: mount path does not exist: %s\n" "$YELLOW" "$NC" "$host" >&2
        continue
      }

      if [[ -z "$cont" ]]; then
        base="${host##*/}"
        cont="/mnt/${base}"
      fi
      [[ "$cont" == /* ]] || cont="/mnt/${cont}"

      # Prevent MSYS conversion for container side by using '//' prefix
      cont="//${cont#/}"

      args+=(-v "${host}:${cont}")
    done
  fi

  # Optional docker sock
  if [[ "${sock:-0}" == 1 ]]; then
    args+=(-v "/var/run/docker.sock:/var/run/docker.sock")
  fi

  # Publish ports
  local pub
  for pub in "${pubs[@]}"; do
    [[ -n "$pub" ]] || continue
    args+=(-p "$pub")
  done

  if [[ "$keepalive" == 1 ]]; then
    # Keepalive mode replaces the image command; disable image healthcheck to avoid false "unhealthy".
    args+=(--no-healthcheck --entrypoint sh "$tag" -c "trap : TERM INT; sleep infinity & wait")
  else
    args+=("$tag")
  fi

  printf "%b[run]%b Starting container %b%s%b\n" "$CYAN" "$NC" "$BLUE" "$name" "$NC"

  # IMPORTANT: don't hide errors; if it fails, you need to see why
  if ! "${args[@]}"; then
    printf "%b[run]%b docker run failed.\n" "$RED" "$NC" >&2
    return 1
  fi
  printf "\n"
}

run_exec_shell() {
  local name="$1"
  if docker exec "$name" sh -lc 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
    exec docker exec -it "$name" bash
  else
    exec docker exec -it "$name" sh
  fi
}

cmd_run() {
  local action="*" dir="$PWD" name="" tag="" nobuild=0 keepalive=1 sock=0 host_os=""
  local -a publish=() mounts=()
  local open_port="" open_path="/" open_proto="http"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    stop | rm | ps | shell | logs | open | "*")
      action="$1"
      shift
      ;;
    build)
      action="*"
      shift
      ;;
    --name)
      name="${2:-}"
      shift 2
      ;;
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --no-build)
      nobuild=1
      shift
      ;;
    --no-keepalive)
      keepalive=0
      shift
      ;;
    --sock)
      sock=1
      shift
      ;;
    --host-os)
      host_os="${2:-}"
      shift 2
      ;;
    -p | --publish)
      publish+=("${2:-}")
      shift 2
      ;;
    --mount)
      mounts+=("${2:-}")
      shift 2
      ;;
    --port)
      open_port="${2:-}"
      shift 2
      ;;
    --path)
      open_path="${2:-/}"
      shift 2
      ;;
    --https)
      open_proto="https"
      shift
      ;;
    --http)
      open_proto="http"
      shift
      ;;
    *) break ;;
    esac
  done

  # Host path (POSIX) for planning/labels
  local dir_posix
  dir_posix="$(cd "$dir" && pwd -P)"

  if [[ -z "$host_os" ]]; then
    host_os="${HOST_OS:-$(detect_host_os)}"
  fi

  # Docker path (may need Windows form for docker.exe)
  local dir_docker="$dir_posix"

  # Windows Git Bash/MSYS hardening:
  # - stop MSYS rewriting container paths (/workspace -> D:/Program Files/Git/workspace)
  # - but still feed docker.exe Windows-absolute host paths for build/run contexts
  if is_windows_shell; then
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    if has_cmd cygpath; then
      dir_docker="$(cygpath -w "$dir_posix")"
    fi
  fi

  # Plan/name/tag should be based on the real project identity (POSIX dir)
  IFS='|' read -r def_name def_tag _def_dir < <(run_plan "$dir_posix")
  name="${name:-$def_name}"

  # Tag rules:
  # - Default tag is ":local" (from run_plan)
  # - If user passes --tag without ":", append ":local"
  if [[ -n "${tag:-}" ]]; then
    if [[ "$tag" != *:* ]]; then
      tag="${tag}:local"
    fi
  else
    tag="$def_tag"
  fi

  _find_for_dir() {
    local found
    found="$(run_find_container "$dir_posix" || true)"
    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return 0
    fi
    if docker inspect "$name" >/dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
    return 1
  }

  _run_build_summary() {
    local img="$1" build_dir="$2" cname="$3"
    local tag_only="${img##*:}"

    printf "\n%b[run]%b Build summary\n" "$CYAN" "$NC"
    printf "  %bImage:%b     %s\n" "$BOLD" "$NC" "$img"
    printf "  %bTag:%b       %s\n" "$BOLD" "$NC" "$tag_only"
    printf "  %bDir:%b       %s\n" "$BOLD" "$NC" "$build_dir"
    printf "  %bName:%b      %s\n" "$BOLD" "$NC" "$cname"
    printf "  %bKeepalive:%b %s\n" "$BOLD" "$NC" "$keepalive"
    printf "  %bSock:%b      %s\n" "$BOLD" "$NC" "$sock"
    printf "  %bHost OS:%b   %s\n" "$BOLD" "$NC" "$host_os"

    if ((${#publish[@]})); then
      printf "  %bPublish:%b   %s\n" "$BOLD" "$NC" "${publish[*]}"
    else
      printf "  %bPublish:%b   (none)\n" "$BOLD" "$NC"
    fi

    if ((${#mounts[@]})); then
      printf "  %bMounts:%b    %s\n" "$BOLD" "$NC" "${mounts[*]}"
    else
      printf "  %bMounts:%b    (none)\n" "$BOLD" "$NC"
    fi
    printf "\n"
  }

  _run_runtime_summary() {
    local cname="$1"
    local id img state ports
    id="$(docker inspect -f '{{.Id}}' "$cname" 2>/dev/null | cut -c1-12 || true)"
    img="$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || true)"
    state="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || true)"
    ports="$(docker port "$cname" 2>/dev/null | sed '/^[[:space:]]*$/d' | tr '\n' '; ' | sed 's/; $//' || true)"

    printf "%b[run]%b Runtime summary\n" "$CYAN" "$NC"
    printf "  %bContainer:%b %s\n" "$BOLD" "$NC" "${cname}${id:+ ($id)}"
    [[ -n "$img" ]] && printf "  %bImage:%b     %s\n" "$BOLD" "$NC" "$img"
    [[ -n "$state" ]] && printf "  %bState:%b     %s\n" "$BOLD" "$NC" "$state"
    if [[ -n "$ports" ]]; then
      printf "  %bPorts:%b     %s\n" "$BOLD" "$NC" "$ports"
    else
      printf "  %bPorts:%b     (none published)\n" "$BOLD" "$NC"
    fi
    printf "%b\n[run]%b Example Usage (in Composer)\n" "$CYAN" "$NC"
    printf "  %bimage:%b %s\n" "$BOLD" "$NC" "$img"
    printf "  %bpull_policy:%b never\n" "$BOLD" "$NC"
    printf "\n"
  }

  case "$action" in
  ps)
    docker ps -a --filter "label=com.infocyph.lds.run=1" \
      --format 'table {{.Names}}	{{.Image}}	{{.Status}}	{{.Labels}}'
    return 0
    ;;
  stop)
    local existing
    existing="$(_find_for_dir)" || die "no run container found for: $dir_posix"
    docker stop "$existing" >/dev/null
    printf "%b[run]%b Stopped %s\n" "$GREEN" "$NC" "$existing"
    return 0
    ;;
  logs)
    local existing
    existing="$(_find_for_dir)" || die "no run container found for: $dir_posix"
    exec docker logs -f "$existing"
    ;;
  open)
    local existing line addr hp url
    existing="$(_find_for_dir)" || die "no run container found for: $dir_posix"

    [[ -n "$open_path" ]] || open_path="/"
    [[ "$open_path" == /* ]] || open_path="/$open_path"

    if [[ -n "$open_port" ]]; then
      line="$(docker port "$existing" "$open_port" 2>/dev/null | head -n 1 || true)"
      [[ -n "$line" ]] || line="$(docker port "$existing" "${open_port}/tcp" 2>/dev/null | head -n 1 || true)"
    else
      line="$(docker port "$existing" 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -z "$line" ]]; then
      printf "%b[run]%b No published ports found.\n" "$YELLOW" "$NC"
      printf "%b[run]%b Tip: start with %blds run --publish 8025:8025%b then %blds run open%b\n" \
        "$YELLOW" "$NC" "$BLUE" "$NC" "$BLUE" "$NC"
      return 1
    fi

    addr="${line##*-> }"
    hp="${addr##*:}"
    url="${open_proto}://localhost:${hp}${open_path}"
    open_url "$url"
    printf "%b[run]%b Opened: %s\n" "$GREEN" "$NC" "$url"
    return 0
    ;;
  rm)
    local existing img
    existing="$(_find_for_dir)" || true
    if [[ -n "${existing:-}" ]]; then
      img="$(docker inspect -f '{{.Config.Image}}' "$existing" 2>/dev/null || true)"
      docker stop "$existing" >/dev/null 2>&1 || true
      docker rm "$existing" >/dev/null 2>&1 || true
      printf "%b[run]%b Removed container %s\n" "$GREEN" "$NC" "$existing"
      if [[ -n "${img:-}" ]]; then
        docker rmi -f "$img" >/dev/null 2>&1 || true
        printf "%b[run]%b Removed image %s\n" "$GREEN" "$NC" "$img"
      fi
    else
      printf "%b[run]%b No container found for %s\n" "$YELLOW" "$NC" "$dir_posix"
    fi
    return 0
    ;;
  shell | "*")
    if ((nobuild == 0)); then
      # Build needs docker.exe-friendly path on Windows
      run_build "$tag" "$dir_docker"
    else
      printf "%b[run]%b Skipping build (--no-build)\n" "$YELLOW" "$NC"
    fi

    _run_build_summary "$tag" "$dir_posix" "$name"

    if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
      printf "%b[run]%b Container already running: %s\n\n" "$GREEN" "$NC" "$name"
    else
      if docker inspect "$name" >/dev/null 2>&1; then
        docker rm -f "$name" >/dev/null 2>&1 || true
      fi

      # Keep mounts as user gave them (POSIX/relative); run_start should validate POSIX
      # and convert host-side to Windows only at docker run time.
      run_start "$name" "$tag" "$dir_docker" "$keepalive" "$sock" "$host_os" \
        "${publish[@]}" -- "${mounts[@]}"
    fi

    _run_runtime_summary "$name"

    # "shell" enters the container; "*" / "build" does not.
    if [[ "$action" == "shell" ]]; then
      run_exec_shell "$name"
    else
      printf "%b[run]%b Built/started. Use %blds run shell%b to enter, %blds run logs%b to follow logs.\n" \
        "$GREEN" "$NC" "$BLUE" "$NC" "$BLUE" "$NC"
      return 0
    fi
    ;;
  esac
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

###############################################################################
# 6x. GROUPED COMMAND ROUTERS (stack/domain/support) + backward-compatible aliases
###############################################################################

cmd_stack() {
  local sub="${1:-}"
  shift || true
  case "${sub,,}" in
  "" | help | -h | --help) cmd_help stack ;;
  up) cmd_up "$@" ;;
  start) cmd_start "$@" ;;
  down | stop) cmd_down "$@" ;;
  restart | reboot) cmd_restart "$@" ;;
  status) cmd_status "$@" ;;
  ps) cmd_ps "$@" ;;
  logs) cmd_logs "$@" ;;
  exec) cmd_exec "$@" ;;
  events) cmd_events "$@" ;;
  clean) cmd_clean "$@" ;;
  config) cmd_config "$@" ;; diff) cmd_stack_diff "$@" ;;

  http) cmd_http "$@" ;;
  *)
    die "stack <up|down|restart|status|ps|logs|exec|events|clean|config|http>"
    ;;
  esac
}

# Canonical: domain. Legacy: host.
cmd_domain() {
  local sub="${1:-}"
  shift || true
  case "${sub,,}" in
  "" | help | -h | --help) die "domain <add|rm|ls>" ;;
  add) cmd_host add "$@" ;;
  rm | remove | del | delete) cmd_host rm "$@" ;;
  ls | list) cmd_host list "$@" ;;
  *)
    die "domain <add|rm|ls>"
    ;;
  esac
}

cmd_support() {
  local sub="${1:-}"
  shift || true
  case "${sub,,}" in
  "" | help | -h | --help) die "support <open|bundle|notify|ui|trace>" ;;
  open) cmd_open "$@" ;;
  bundle) cmd_bundle "$@" ;;
  notify) cmd_notify "$@" ;;
  ui) cmd_ui "$@" ;;
  *)
    die "support <open|bundle|notify|ui|trace>"
    ;;
  esac
}

# Minimal support bundle (shareable diagnostics zip)
# Modes:
#   --redact : remove secrets-like env lines from captured env/config outputs (best-effort)
#   --full   : include more logs/inspect output (can be large)
cmd_bundle() {
  local mode="redact"
  local out="${1:-}"
  while [[ "${1:-}" ]]; do
    case "$1" in
    --redact)
      mode="redact"
      shift
      ;;
    --full)
      mode="full"
      shift
      ;;
    *.zip)
      out="$1"
      shift
      ;;
    *) break ;;
    esac
  done

  need zip
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local project
  project="$(lds_project)"
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/lds_bundle.XXXXXX")"
  local base="lds_bundle_${project}_${ts}"
  [[ -n "$out" ]] || out="$PWD/${base}.zip"

  cleanup_bundle() { rm -rf "$tmp" 2>/dev/null || true; }
  trap cleanup_bundle RETURN

  {
    echo "project=$project"
    echo "dir=$DIR"
    echo "time=$ts"
    echo "mode=$mode"
  } >"$tmp/meta.txt"

  # compose config (effective)
  {
    echo "# docker compose config"
    docker_compose config 2>&1 || true
  } >"$tmp/compose.config.txt"

  # ps + networks
  docker_compose ps >"$tmp/compose.ps.txt" 2>&1 || true
  docker network ls >"$tmp/docker.networks.txt" 2>&1 || true

  # container list + inspect (scoped)
  docker ps --filter "label=com.docker.compose.project=$project" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
    >"$tmp/docker.ps.txt" 2>&1 || true

  if [[ "$mode" == "full" ]]; then
    docker inspect $(docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null) \
      >"$tmp/docker.inspect.json" 2>/dev/null || true
  fi

  # recent logs (tail)
  docker_compose logs --no-color --tail 400 >"$tmp/compose.logs.txt" 2>&1 || true

  # vhost configs
  if [[ -d "$DIR/configuration/nginx" ]]; then
    mkdir -p "$tmp/nginx"
    cp -a "$DIR/configuration/nginx/." "$tmp/nginx/" 2>/dev/null || true
  fi

  # env files (redacted best-effort)
  mkdir -p "$tmp/env"
  if [[ -r "$ENV_MAIN" ]]; then
    if [[ "$mode" == "redact" ]]; then
      sed -E 's/^([A-Za-z0-9_]+)=.*/\1=REDACTED/' "$ENV_MAIN" >"$tmp/env/.env"
    else
      cp -a "$ENV_MAIN" "$tmp/env/.env" 2>/dev/null || true
    fi
  fi
  if [[ -r "$ENV_DOCKER" ]]; then
    if [[ "$mode" == "redact" ]]; then
      sed -E 's/^([A-Za-z0-9_]+)=.*/\1=REDACTED/' "$ENV_DOCKER" >"$tmp/env/docker.env"
    else
      cp -a "$ENV_DOCKER" "$tmp/env/docker.env" 2>/dev/null || true
    fi
  fi

  # tools-side quick diagnostics (inside network)
  {
    echo "# ip r / ip a / ss"
    _tools_exec "ip r; echo; ip a; echo; ss -tulpen 2>/dev/null || true"
  } >"$tmp/tools.net.txt" 2>&1 || true

  # pack
  (cd "$tmp" && zip -qr "$out" .) || die "Failed to write bundle: $out"
  ok "Bundle created: $out"
}

cmd_help() {

  if [[ "${1:-}" == "--markdown" ]]; then
    cat <<'MD'
# LocalDevStack (lds) — Command Reference

## Stack (compose)
- `lds stack up`  *(aliases: `up`)*
- `lds stack start`  *(aliases: `start`)*
- `lds stack down [--volumes --yes]`  *(aliases: `down`, `stop`)*
- `lds stack restart [svc]`  *(aliases: `restart`, `reboot`)*
- `lds stack status [status-args…]`  *(alias: `status`; forwards args to tools `status`)*
- `lds stack ps`  *(alias: `ps`)*
- `lds stack logs [svc] [--follow] [--since <dur>] [--grep <pattern>]`  *(alias: `logs`)*
- `lds stack exec <svc> [cmd…]`  *(alias: `exec`)*
- `lds stack events [--since <dur>]`  *(alias: `events`)*
- `lds stack clean --yes [--volumes]`  *(alias: `clean`)*
- `lds stack diff [--config] [--json]`  *(shows desired vs running images)*


## Domain (vhost lifecycle + routing)
- `lds domain add …`
- `lds domain rm …`
- `lds domain ls`

Legacy alias: `lds host …` → same subcommands as `domain`.

## Certificates (TLS)
- `lds cert status [domain|all]`
- `lds cert regen [domain|all] [--yes]`
- `lds cert diagnose <domain>`
- `lds certificate install`
- `lds certificate uninstall [--all]`

## Diagnostics
- `lds diag dns <domain>`
- `lds diag net`
- `lds diag tcp <host> <port>`
- `lds diag http <url>` *(alias: `sniff <url>`)*
- `lds diag tls <domain>`

## Config
- `lds config show [--json]`
- `lds config services`
- `lds config profiles`
- `lds config env-used`
- `lds config validate`

## Support
- `lds support open <mail|db|redis|kibana|domain>
  support trace <domain>`
- `lds support bundle [--redact|--full]`
- `lds support notify …`
- `lds support ui`

Shortcuts: `open`, `bundle`, `notify`, `ui` map to `support …`.

## Secrets (senv)
- `lds secrets …`

## Tools (project server-tools container)
- `lds tools sh`
- `lds tools exec "<cmd>"`
- `lds tools file <path>`

## AI
- `lds ai status|ask|explain|troubleshoot|review|repo-review|graphify …`
- `lds llm models|ps|show|pull|rm|unload|run|ask|chat|prompt|code|review|json|ai-commit …`
- `lds llm runtime <cpu|nvidia|amd>`
- `lds llm host-port <status|on|off>`

## Setup
- `lds setup init|permissions|domain|profiles`

## Runner (ad‑hoc Dockerfile runner)
- `lds run` *(default: build+start only)* / `lds run shell` *(build+start+enter)* / `lds run *` *(same as default)* (+ `ps|logs|stop|rm|open` and flags: `--publish|-p`, `--no-keepalive`, `--mount`, `--sock`, `--host-os`, `--tag`, `--name`)

## Other
- `lds rebuild [all|<svc…>]`
- `lds core [domain]`

## Short client wrappers
- `lds php|composer|node|npm|npx …`
- `lds my|mysql|mysqldump …`
- `lds maria|mariadb|mariadb-dump …`
- `lds pg|psql|pg_dump|pg_restore …`
- `lds redis|redis-cli …`
MD
    return 0
  fi

  cat <<EOF
${BOLD}LocalDevStack (lds)${NC}

${CYAN}Stack (compose):${NC}
  stack up|start|down|restart|status|ps|logs|exec|events|clean|config|diff
  up                               Alias of: stack up
  start                            Alias of: stack start
  down|stop                        Alias of: stack down
  restart|reboot                   Alias of: stack restart
  status|ps|logs|exec|events       Alias of: stack <...>
  clean                            Alias of: stack <...>

${CYAN}Domain (vhosts + routing):${NC}
  domain add|rm|ls
  host add|rm|list                 Legacy alias of: domain <...>

${CYAN}Certificates (TLS):${NC}
  cert status|regen|diagnose
  certificate install|uninstall [--all]

${CYAN}Diagnostics:${NC}
  diag dns|net|tcp|http|tls
  sniff <url>                      Alias of: diag http <url>

${CYAN}Config:${NC}
  config show|services|profiles|env-used|validate

${CYAN}Support:${NC}
  support open <mail|db|redis|kibana|domain>
  support trace <domain>
  support bundle [--redact|--full]
  support notify ...
  support ui
  open|bundle|notify|ui             Shortcuts → support <...>

${CYAN}Secrets:${NC}
  secrets <senv-args...>

${CYAN}Tools (project server-tools container):${NC}
  tools sh|exec|file

${CYAN}AI:${NC}
  ai status|ask|explain|troubleshoot|review|repo-review|graphify
  llm models|ps|show|pull|rm|unload|run|ask|chat|prompt|code|review|json|ai-commit
  llm runtime <cpu|nvidia|amd>
  llm host-port <status|on|off>

${CYAN}Setup:${NC}
  setup init|permissions|domain|profiles

${CYAN}Runner (ad-hoc Dockerfile runner):${NC}
  run [ps|logs|stop|rm|open] [--publish|-p A:B] [--no-keepalive] [--mount HOST[:CONT]] [--sock] [--host-os VALUE]

${CYAN}Other:${NC}
  rebuild [all|<svc…>]
  core [domain]

${CYAN}Help:${NC}
  help [--markdown]

EOF
}

###############################################################################
# 7. MAIN
###############################################################################
main() {
  [[ $# -gt 0 ]] || {
    cmd_help
    exit 1
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -v | --verbose)
      VERBOSE=1
      QUIET=0
      shift
      ;;
    -q | --quiet)
      QUIET=1
      VERBOSE=0
      shift
      ;;
    --reload-extras)
      export LDS_EXTRAS_RELOAD=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -h | --help)
      cmd_help
      exit 0
      ;;
    -*) die "Unknown global option: $1" ;;
    *) break ;;
    esac
  done

  [[ $# -gt 0 ]] || {
    cmd_help
    exit 1
  }

  local cmd="${1,,}"
  shift || true

  if [[ "$cmd" == "help" ]]; then
    cmd_help "$@"
    exit 0
  fi

  # Do not require docker for pure help output; everything else expects the stack.
  need docker

  case "$cmd" in
  php | composer | node | npm | npx) exec "$DIR/bin/$cmd" "$@" ;;
  pg | psql | pg_restore | pg-restore | pgrestore | pg_dump | pgdump | pg-dump) exec "$DIR/bin/pg" "$@" ;;
  maria | mariadb | mariadbdump | mariadb-dump | mariadb_dump) exec "$DIR/bin/maria" "$@" ;;
  my | mysql | mysqldump | mysql-dump | mysql_dump) exec "$DIR/bin/my" "$@" ;;
  redis | redis-cli) exec "$DIR/bin/redis-cli" "$@" ;;
  es | elastic | elasticsearch) exec "$DIR/bin/es" "$@" ;;
  mongo | mongodb | mongosh | mongoimport | mongoexport) exec "$DIR/bin/mongo" "$@" ;;
  ai) cmd_ai "$@" ;;
  llm) cmd_llm "$@" ;;
  vpn-fix) cmd_vpn_fix "$@" ;;
  *)
    if declare -F "cmd_$cmd" >/dev/null 2>&1; then
      "cmd_$cmd" "$@"
    else
      exec "$DIR/bin/tool-runner" "$cmd" "$@"
    fi
    ;;
  esac
}

main "$@"
