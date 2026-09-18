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

# Read a single dotenv value without sourcing/evaluating the file.
# Only literal KEY=VALUE state is accepted; nothing is executed.
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

# Resolution mirrors Compose intent: shell > user docker/.env > release.env > fallback.
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

# ── compose extras (docker/extras/*.y{a,}ml) ────────────────────────────────
__EXTRAS_LOADED=0
declare -a __EXTRA_FILES=()

load_extras() {
  # Set LDS_EXTRAS_RELOAD=1 (or global --reload-extras) to re-scan templates every call.
  if [[ "${LDS_EXTRAS_RELOAD:-0}" == "1" ]]; then
    __EXTRAS_LOADED=0
  fi

  ((__EXTRAS_LOADED)) && return 0
  __EXTRAS_LOADED=1

  [[ -d "$EXTRAS_DIR" ]] || return 0

  mapfile -t __EXTRA_FILES < <(
    find "$EXTRAS_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null | sort | sed '/^[[:space:]]*$/d'
  )
}

docker_compose() {
  load_extras
  # Create required runtime files only when docker/compose operations are invoked.
  ((EUID == 0)) || ensure_files_exist "/docker/.env" "/configuration/php/php.ini" "/.env"
  if [[ -z "${__LDS_DC_BIN:-}" ]]; then
    if docker compose version >/dev/null 2>&1; then
      __LDS_DC_BIN=(docker compose)
    else
      __LDS_DC_BIN=(docker-compose)
    fi
  fi

  [[ -r "$ENV_RELEASE" ]] || die "Missing release compatibility manifest: $ENV_RELEASE"

  # Release defaults are loaded first; user docker/.env overrides them.
  # Shell variables remain higher-precedence Compose interpolation inputs.
  local -a env_files=(--env-file "$ENV_RELEASE")
  [[ -r "$ENV_DOCKER" ]] && env_files+=(--env-file "$ENV_DOCKER")

  # Static LocalDevStack overrides are selected from controlled state.
  local ai_runtime ai_host_port
  local -a static_f=()
  ai_runtime="$(compose_control_value LDS_AI_RUNTIME cpu)"
  case "${ai_runtime,,}" in
  "" | cpu) ;;
  nvidia) static_f+=(-f "$CFG/compose/ai-nvidia.yaml") ;;
  amd) static_f+=(-f "$CFG/compose/ai-amd.yaml") ;;
  *) die "Invalid LDS_AI_RUNTIME: $ai_runtime (expected cpu|nvidia|amd)" ;;
  esac

  ai_host_port="$(compose_control_value LDS_LLM_HOST_PORT 0)"
  case "${ai_host_port,,}" in
  "" | 0 | false | no | off) ;;
  1 | true | yes | on) static_f+=(-f "$CFG/compose/ai-host-port.yaml") ;;
  *) die "Invalid LDS_LLM_HOST_PORT: $ai_host_port (expected 0|1)" ;;
  esac

  # Build -f list (stable order; product overrides before user extras).
  local -a extra_f=() f
  for f in "${__EXTRA_FILES[@]:-}"; do
    [[ -f "$f" ]] || continue
    case "$f" in
    *.yml | *.yaml) extra_f+=(-f "$f") ;;
    esac
  done

  local host_os="${HOST_OS:-$(detect_host_os)}"

  HOST_OS="$host_os" "${__LDS_DC_BIN[@]}" \
    --project-directory "$DIR" \
    -f "$COMPOSE_FILE" \
    "${static_f[@]}" \
    "${extra_f[@]}" \
    "${env_files[@]}" \
    "$@"
}

# helper: print project name
lds_project() { printf '%s' "${__LDS_PROJECT:-$(basename -- "$DIR")}"; }

# (QUIET by default) ────────────────────────────────
# Centralize quiet/verbose handling for compose subcommands.
# Usage: dc_cmd <up|pull|build> [args...]
dc_cmd() {
  local sub="${1:-}"
  shift || true

  local -a quiet=()
  if ((VERBOSE == 0)); then
    case "$sub" in
    up) quiet+=(--quiet-pull) ;;
    pull) quiet+=(-q) ;;
    build) quiet+=(--quiet) ;;
    esac
  fi

  docker_compose "$sub" "${quiet[@]}" "$@"
}

dc_up() { dc_cmd up "$@"; }
dc_pull() { dc_cmd pull "$@"; }
dc_build() { dc_cmd build "$@"; }

# helper for our own minimal logging (still shows in quiet mode)
logv() { ((VERBOSE)) && printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2 || true; }
logq() { printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2; }

###############################################################################
# 1b. PROMPTS + DOTENV HELPERS
###############################################################################

# Unified prompt helper (used by env_init + profiles)
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

# ── dotenv quoting: only quote when needed (spaces, tabs, #, quotes, leading/trailing whitespace) ──
env_quote() {
  # Wrap in double-quotes and escape backslash + double-quote + newlines
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

env_quote_if_needed() {
  local v=${1-}

  # Already quoted (single or double) => keep as-is
  if [[ "$v" =~ ^\".*\"$ || "$v" =~ ^\'.*\'$ ]]; then
    printf '%s' "$v"
    return 0
  fi

  # Leading/trailing whitespace or any internal whitespace or # or quotes => quote
  if [[ "$v" =~ ^[[:space:]] || "$v" =~ [[:space:]]$ || "$v" == *$'\t'* || "$v" == *" "* || "$v" == *"#"* || "$v" == *"\""* ]]; then
    env_quote "$v"
    return 0
  fi

  printf '%s' "$v"
}

# Escape replacement for sed (delimiter '|')
sed_escape_repl() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//&/\\&}
  s=${s//|/\\|}
  printf '%s' "$s"
}

update_env() {
  local file=$1 var=$2 val=${3-}
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || {
    printf "%bFile '%s' not found. Creating one.%b\n" "$YELLOW" "$file" "$NC"
    : >"$file"
  }

  # Apply quoting only when needed (spaces etc.)
  val="$(env_quote_if_needed "$val")"

  # Sed-safe replacement
  local val_sed
  val_sed="$(sed_escape_repl "$val")"

  var=$(echo "$var" | sed 's/[]\/$*.^|[]/\\&/g')
  if grep -qE "^[# ]*$var=" "$file" 2>/dev/null; then
    sed -Ei "s|^[# ]*($var)=.*|\1=$val_sed|" "$file"
  else
    printf "%s=%s\n" "$var" "$val" >>"$file"
  fi
}

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
# 2. INSTALL / PERMISSIONS (HOST)
###############################################################################
add_to_windows_path() {
  [[ "$OSTYPE" =~ (msys|cygwin) ]] || return 0
  has_cmd cygpath || return 0

  # Only add if lds.bat exists where we think it is
  [[ -f "$DIR/lds.bat" ]] || return 0

  local win_repo
  win_repo="$(cygpath -w "$DIR")"

  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    \$t = '$win_repo'
    \$cur = [Environment]::GetEnvironmentVariable('Path','User')
    if ([string]::IsNullOrWhiteSpace(\$cur)) { \$cur = '' }

    # Normalize (trim + case-insensitive compare) to avoid duplicates
    \$parts = \$cur -split ';' | ForEach-Object { \$_.Trim() } | Where-Object { \$_ }
    \$exists = \$false
    foreach (\$p in \$parts) { if (\$p.ToLowerInvariant() -eq \$t.ToLowerInvariant()) { \$exists = \$true; break } }

    if (-not \$exists) {
      \$new = (\$parts + \$t) -join ';'
      [Environment]::SetEnvironmentVariable('Path', \$new, 'User')
    }
  " >/dev/null 2>&1 || true
}

fix_perms() {
  if [[ "$OSTYPE" =~ (msys|cygwin) ]]; then
    add_to_windows_path
    printf "%bWindows PATH configured.%b\n" "$GREEN" "$NC"
    return 0
  fi

  ((EUID == 0)) || die "Please run with sudo."

  chmod 755 "$DIR"
  chmod 2775 "$DIR/configuration"
  find "$DIR/configuration" -type f ! -perm 664 -exec chmod 664 {} +

  chmod 755 "$DIR/docker"
  find "$DIR/docker" -type f ! -perm 644 -exec chmod 644 {} +

  chmod -R 777 "$DIR/logs"
  chown -R "$USER:docker" "$DIR/logs"

  chmod 755 "$DIR/bin"
  find "$DIR/bin" -type f -exec chmod +x {} +
  chmod +x "$DIR/lds"

  ln -fs "$DIR/lds" /usr/local/bin/lds
  printf "%bPermissions assigned.%b\n" "$GREEN" "$NC"
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

# ─────────────────────────────────────────────────────────────────────────────
# Profiles
# ─────────────────────────────────────────────────────────────────────────────

###############################################################################
# 3a. PROFILES: DEFINITIONS + SETUP FLOW
###############################################################################

declare -A SERVICES=(
  [POSTGRESQL]="postgresql"
  [MYSQL]="mysql"
  [MARIADB]="mariadb"
  [ELASTICSEARCH]="elasticsearch"
  [MONGODB]="mongodb"
  [REDIS]="redis"
)

declare -a SERVICE_ORDER=(POSTGRESQL MYSQL MARIADB ELASTICSEARCH MONGODB REDIS)

declare -A PROFILE_ENV=(
  [elasticsearch]="ELASTICSEARCH_VERSION=9.3.0"
  [mysql]="MYSQL_VERSION=latest MYSQL_ROOT_PASSWORD=12345 MYSQL_USER=infocyph MYSQL_PASSWORD=12345 MYSQL_DATABASE=localdb"
  [mariadb]="MARIADB_VERSION=latest MARIADB_ROOT_PASSWORD=12345 MARIADB_USER=infocyph MARIADB_PASSWORD=12345 MARIADB_DATABASE=localdb"
  [mongodb]="MONGODB_VERSION=latest MONGODB_ROOT_USERNAME=root MONGODB_ROOT_PASSWORD=12345"
  [redis]="REDIS_VERSION=latest"
  [postgresql]="POSTGRES_VERSION=latest POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres POSTGRES_DATABASE=postgres"
)

declare -a PENDING_ENVS=()
declare -a PENDING_PROFILES=()

queue_env() { PENDING_ENVS+=("$1"); }
queue_profile() { PENDING_PROFILES+=("$1"); }

flush_envs() {
  local env_file="$ENV_DOCKER" kv key val
  for kv in "${PENDING_ENVS[@]}"; do
    IFS='=' read -r key val <<<"$kv"
    update_env "$env_file" "$key" "$val"
  done
}

flush_profiles() {
  local profile
  for profile in "${PENDING_PROFILES[@]}"; do
    modify_profiles add "$profile"
  done
}

# ── setup menu (selection-first) ──────────────────────────────────────────────

setup_menu_print() {
  # Print menu to stderr to avoid stdout buffering in some Windows wrappers.
  {
    printf "\n%bSetup profiles%b (will replace previous configuration, if exists):\n\n" "$CYAN" "$NC"
    local i=1 key slug
    for key in "${SERVICE_ORDER[@]}"; do
      slug="${SERVICES[$key]}"
      printf "  %2d) %-12s  (%s)\n" "$i" "$key" "$slug"
      i=$((i + 1))
    done
    printf "\n  a) ALL\n"
    printf "  n) NONE / Back\n\n"
  } >&2
}

# Parse user selection into indices or ALL/NONE (prints one token per line)
setup_menu_parse() {
  local input="${1//[[:space:]]/}"
  [[ -n "$input" ]] || return 1
  input="${input//;/,}"

  echo "$input" | tr ',' '\n' | awk '
    BEGIN { ok=1 }
    /^[0-9]+-[0-9]+$/ {
      split($0,a,"-")
      if (a[1] > a[2]) { t=a[1]; a[1]=a[2]; a[2]=t }
      for (i=a[1]; i<=a[2]; i++) print i
      next
    }
    /^[0-9]+$/ { print $0; next }
    /^[aA]$/ { print "ALL"; next }
    /^[nN]$/ { print "NONE"; next }
    { ok=0 }
    END { if (!ok) exit 2 }
  '
}

# Outputs: newline-separated service KEYS from SERVICE_ORDER (e.g. MYSQL, REDIS)
setup_choose_services() {
  local ans parsed
  while :; do
    setup_menu_print
    tty_readline ans "Select (e.g. 1,3,5 or 2-4 or a): " || return 1

    if ! parsed="$(setup_menu_parse "$ans" 2>/dev/null)"; then
      printf "%bInvalid selection.%b Try again.\n" "$YELLOW" "$NC"
      continue
    fi

    if grep -qx "NONE" <<<"$parsed"; then
      return 1
    fi

    if grep -qx "ALL" <<<"$parsed"; then
      printf "%s\n" "${SERVICE_ORDER[@]}"
      return 0
    fi

    # Indices -> keys (de-dupe, preserve order)
    local -A seen=()
    local out=()
    local idx key
    while IFS= read -r idx; do
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      ((idx >= 1 && idx <= ${#SERVICE_ORDER[@]})) || continue
      key="${SERVICE_ORDER[idx - 1]}"
      [[ -n "${seen[$key]:-}" ]] && continue
      seen[$key]=1
      out+=("$key")
    done <<<"$parsed"

    if ((${#out[@]} == 0)); then
      printf "%bNo valid items selected.%b\n" "$YELLOW" "$NC"
      continue
    fi

    printf "%s\n" "${out[@]}"
    return 0
  done
}

setup_service() {
  local service="$1"
  local profile="${SERVICES[$service]:-}"
  [[ -n "$profile" ]] || die "Unknown service: $service"

  printf "\n%b→ %s%b\n" "$YELLOW" "$service" "$NC"
  queue_profile "$profile"

  printf "%bEnter value(s) for %s:%b\n" "$BLUE" "$service" "$NC"
  local pair key def val
  for pair in ${PROFILE_ENV[$profile]}; do
    IFS='=' read -r key def <<<"$pair"
    val=$(read_default "$key" "$def")
    queue_env "$key=$val"
  done
}

process_all() {
  local selected
  if ! selected="$(setup_choose_services)"; then
    printf "\n%bSetup cancelled.%b\n" "$YELLOW" "$NC"
    return 0
  fi

  printf "\n%bWill configure:%b\n" "$CYAN" "$NC"
  while IFS= read -r svc; do
    printf "  - %s (%s)\n" "$svc" "${SERVICES[$svc]}"
  done <<<"$selected"
  echo

  local svc
  while IFS= read -r svc; do
    setup_service "$svc"
  done <<<"$selected"

  flush_envs
  flush_profiles
  printf "\n%b✅ Selected services configured!%b\n" "$GREEN" "$NC"
}

###############################################################################
# 5. ENVIRONMENT + CERT / CA
###############################################################################
detect_timezone() {
  if has_cmd timedatectl; then
    timedatectl show -p Timezone --value
  elif [[ -n ${TZ-} ]]; then
    printf '%s' "$TZ"
  elif [[ -r /etc/timezone ]]; then
    </etc/timezone
  elif has_cmd powershell.exe; then
    powershell.exe -NoProfile -Command "[System.TimeZoneInfo]::Local.Id" 2>/dev/null | tr -d '\r'
  else
    date +%Z
  fi
}

env_init() {
  local env_file="$ENV_DOCKER"
  printf "%bBootstrapping environment defaults…%b\n" "$YELLOW" "$NC"

  local default_tz tz
  default_tz="$(detect_timezone)"
  tz="$(read_default "Timezone (TZ)" "$default_tz")"

  local default_git_name default_git_email git_name git_email
  default_git_name="$(git config --global --get user.name 2>/dev/null || true)"
  default_git_email="$(git config --global --get user.email 2>/dev/null || true)"
  git_name="$(read_default "Git user.name (GIT_USER_NAME)" "$default_git_name")"
  git_email="$(read_default "Git user.email (GIT_USER_EMAIL)" "$default_git_email")"

  # update_env now quotes automatically when needed
  update_env "$env_file" "TZ" "$tz"
  update_env "$env_file" "GIT_USER_NAME" "$git_name"
  update_env "$env_file" "GIT_USER_EMAIL" "$git_email"

  printf "%bConfiguration saved!%b\n" "$GREEN" "$NC"
}

# ─────────────────────────────────────────────────────────────────────────────
# Root CA helpers (cross-distro)
# ─────────────────────────────────────────────────────────────────────────────

# Unique identity (avoid conflicts with other mkcert/dev CAs)
CA_BASENAME="localdevstack-rootca"
CA_NICK="LocalDevStack Root CA"

detect_os_family() {
  # Output: "id|like"
  # Must never fail under set -e
  if [[ "${OSTYPE:-}" =~ (msys|cygwin|win32) ]]; then
    echo "windows|windows"
    return 0
  fi

  local id like
  id="unknown"
  like="unknown"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    id="${ID:-unknown}"
    like="${ID_LIKE:-unknown}"
  elif has_cmd uname; then
    # fallback for macOS / other unix
    case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      id="macos"
      like="darwin"
      ;;
    Linux)
      id="linux"
      like="linux"
      ;;
    esac
  fi

  echo "$id|$like"
}

# Decide destination path + update mechanism. Echo: family|dest|updater
ca_plan() {
  local os_id os_like
  IFS='|' read -r os_id os_like < <(detect_os_family)

  case " $os_id $os_like " in
  *" debian "* | *" ubuntu "* | *" linuxmint "* | *" pop "* | *" raspbian "*)
    printf "debian|/usr/local/share/ca-certificates/${CA_BASENAME}.crt|update-ca-certificates\n"
    ;;
  *" alpine "*)
    printf "alpine|/usr/local/share/ca-certificates/${CA_BASENAME}.crt|update-ca-certificates\n"
    ;;
  *" fedora "* | *" rhel "* | *" redhat "* | *" centos "* | *" rocky "* | *" alma "* | *" amzn "* | *" amazon "* | *" sles "* | *" suse "*)
    printf "rhel|/etc/pki/ca-trust/source/anchors/${CA_BASENAME}.crt|update-ca-trust\n"
    ;;
  *" arch "* | *" manjaro "*)
    printf "arch|/etc/ca-certificates/trust-source/anchors/${CA_BASENAME}.crt|trust\n"
    ;;
  *)
    # best default: Debian-style location (works on many distros even if updater differs)
    printf "fallback|/usr/local/share/ca-certificates/${CA_BASENAME}.crt|\n"
    ;;
  esac
}

is_windows_shell() {
  [[ "${OSTYPE:-}" =~ (msys|cygwin) ]] || [[ -n "${WORKDIR_WIN:-}" ]]
}

need_windows_tools() {
  has_cmd cygpath || die "Windows certificate install needs 'cygpath' (Git Bash)."
  has_cmd powershell.exe || die "Windows certificate install needs 'powershell.exe' on PATH."
}

# Import CA into the invoking user's NSS DB (Chrome/Chromium/Firefox on many Linux setups)
install_ca_nss_user() {
  local ca_file="$1"
  has_cmd certutil || return 0

  local user="${SUDO_USER:-}"
  [[ -n "$user" && "$user" != "root" ]] || return 0

  local home
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0

  local nssdb="sql:${home}/.pki/nssdb"
  sudo -u "$user" mkdir -p "${home}/.pki/nssdb" >/dev/null 2>&1 || true

  if sudo -u "$user" certutil -d "$nssdb" -L 2>/dev/null | grep -Fq "$CA_NICK"; then
    printf "%b✔ NSS already has CA%b (%s)\n" "$GREEN" "$NC" "$user"
    return 0
  fi

  if sudo -u "$user" certutil -d "$nssdb" -A -n "$CA_NICK" -t "C,," -i "$ca_file" >/dev/null 2>&1; then
    printf "%b✔ Imported CA into NSS%b (%s)\n" "$GREEN" "$NC" "$user"
  else
    printf "%bWARN%b: NSS import failed (certutil).\n" "$YELLOW" "$NC" >&2
  fi
}

install_ca_windows() {
  need_windows_tools

  local src_ca="$DIR/configuration/rootCA/rootCA.pem"
  [[ -r "$src_ca" ]] || die "certificate not found: $src_ca"

  local win_ca
  win_ca="$(cygpath -w "$src_ca")"

  printf "%bInstalling root CA into Windows trust store (CurrentUser\\Root)…%b\n" "$CYAN" "$NC"

  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    \$ErrorActionPreference = 'Stop'
    \$path = '$win_ca'
    \$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(\$path)
    \$cert.FriendlyName = '$CA_NICK'

    \$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser')
    \$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

    \$exists = \$store.Certificates | Where-Object { \$_.Thumbprint -eq \$cert.Thumbprint }
    if (-not \$exists) { \$store.Add(\$cert) }

    \$store.Close()
  " >/dev/null 2>&1 || die "Windows certificate install failed (PowerShell import)."

  printf "%bRoot CA installed on Windows%b (CurrentUser\\Root) as %s\n" "$GREEN" "$NC" "$CA_NICK"
  printf "%bNote:%b restart browsers if they still show trust errors.\n" "$YELLOW" "$NC"
}

install_ca() {
  if is_windows_shell; then
    install_ca_windows
    return 0
  fi

  local src_ca="$DIR/configuration/rootCA/rootCA.pem"
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "certificate install requires sudo"
  [[ -r "$src_ca" ]] || die "certificate not found: $src_ca"

  local family dest updater os_id os_like
  IFS='|' read -r os_id os_like < <(detect_os_family)
  IFS='|' read -r family dest updater < <(ca_plan)

  printf "%bInstalling root CA…%b\n" "$CYAN" "$NC"
  printf "%bDetected OS%b: id=%s like=%s → %s\n" "$CYAN" "$NC" "$os_id" "$os_like" "$family"

  install -d -m 755 "$(dirname "$dest")"
  install -m 644 "$src_ca" "$dest"
  printf "%b✔ Copied%b → %s\n" "$GREEN" "$NC" "$dest"

  case "$family" in
  debian | alpine)
    if has_cmd update-ca-certificates; then
      printf "%bUpdating trust store%b (update-ca-certificates)…\n" "$CYAN" "$NC"
      if update-ca-certificates; then
        printf "%b✔ Trust store updated%b\n" "$GREEN" "$NC"
        printf "%bNote:%b If you see \"rehash: skipping ca-certificates.crt…\", that’s normal (it’s a bundle).\n" "$YELLOW" "$NC"
      else
        printf "%bWARN%b: update-ca-certificates failed. CA is installed but may not be active yet.\n" "$YELLOW" "$NC" >&2
      fi
    else
      printf "%bWARN%b: update-ca-certificates not found. CA is installed but auto-update is unavailable.\n" "$YELLOW" "$NC" >&2
    fi

    # Optional p11-kit sync: best-effort only (can be missing helper on minimal installs)
    if has_cmd trust; then
      printf "%bSyncing p11-kit%b (trust extract-compat)…\n" "$CYAN" "$NC"
      if trust extract-compat >/dev/null 2>&1; then
        printf "%b✔ p11-kit trust synced%b\n" "$GREEN" "$NC"
      else
        printf "%bWARN%b: trust extract-compat failed (helper missing on some installs). Skipping.\n" "$YELLOW" "$NC" >&2
      fi
    else
      printf "%bINFO%b: 'trust' not found — skipping p11-kit sync.\n" "$YELLOW" "$NC"
    fi
    ;;
  rhel)
    if has_cmd update-ca-trust; then
      printf "%bUpdating trust store%b (update-ca-trust extract)…\n" "$CYAN" "$NC"
      if update-ca-trust extract; then
        printf "%b✔ Trust store updated%b\n" "$GREEN" "$NC"
      else
        printf "%bWARN%b: update-ca-trust extract failed. CA is installed but may not be active yet.\n" "$YELLOW" "$NC" >&2
      fi
    else
      printf "%bWARN%b: update-ca-trust not found. CA is installed but auto-update is unavailable.\n" "$YELLOW" "$NC" >&2
    fi
    ;;
  arch)
    if has_cmd trust; then
      printf "%bUpdating trust store%b (trust extract-compat)…\n" "$CYAN" "$NC"
      if trust extract-compat >/dev/null 2>&1; then
        printf "%b✔ Trust store updated%b\n" "$GREEN" "$NC"
      else
        printf "%bWARN%b: trust extract-compat failed. CA is installed, but trust sync may be incomplete.\n" "$YELLOW" "$NC" >&2
      fi
    else
      printf "%bWARN%b: 'trust' not found. CA is installed, but trust sync is unavailable.\n" "$YELLOW" "$NC" >&2
    fi
    ;;
  *)
    printf "%bINFO%b: Unknown distro; CA copied to %s.\n" "$YELLOW" "$NC" "$dest"
    printf "%bINFO%b: You may need to update trust store manually for your OS.\n" "$YELLOW" "$NC"
    ;;
  esac

  # Extra: ensure browsers that rely on NSS trust pick it up
  install_ca_nss_user "$src_ca"

  printf "%bRoot CA installed%b → %s (%s)\n" "$GREEN" "$NC" "$dest" "$CA_NICK"
}

uninstall_ca_windows() {
  need_windows_tools

  local src_ca="$DIR/configuration/rootCA/rootCA.pem"
  [[ -r "$src_ca" ]] || die "certificate not found: $src_ca"

  local win_ca
  win_ca="$(cygpath -w "$src_ca")"

  printf "%bUninstalling root CA from Windows trust store (CurrentUser\\Root)…%b\n" "$CYAN" "$NC"

  local removed
  removed="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    \$ErrorActionPreference = 'Stop'
    \$path = '$win_ca'
    \$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(\$path)
    \$thumb = \$cert.Thumbprint

    \$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser')
    \$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

    \$matches = @(\$store.Certificates | Where-Object { \$_.Thumbprint -eq \$thumb })
    foreach (\$c in \$matches) { \$store.Remove(\$c) }

    \$store.Close()
    [string]\$matches.Count
  " 2>/dev/null || true)"

  removed="${removed//[$'\r\n\t ']/}"
  if [[ "${removed:-0}" =~ ^[0-9]+$ ]] && ((removed > 0)); then
    printf "%bRoot CA uninstalled on Windows%b (removed %s cert)\n" "$GREEN" "$NC" "$removed"
  else
    printf "%bRoot CA already absent on Windows%b (no matching cert)\n" "$YELLOW" "$NC"
  fi
}

uninstall_ca_nss_user() {
  has_cmd certutil || return 0
  local user="${SUDO_USER:-}"
  [[ -n "$user" && "$user" != "root" ]] || return 0

  local home
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0

  local nssdb="sql:${home}/.pki/nssdb"
  if sudo -u "$user" certutil -d "$nssdb" -L 2>/dev/null | grep -Fq "$CA_NICK"; then
    sudo -u "$user" certutil -d "$nssdb" -D -n "$CA_NICK" >/dev/null 2>&1 || true
    printf "%b✔ Removed CA from NSS%b (%s)\n" "$GREEN" "$NC" "$user"
  fi
}

uninstall_ca() {
  if is_windows_shell; then
    uninstall_ca_windows
    return 0
  fi

  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "certificate uninstall requires sudo"

  local all=0
  if [[ "${1:-}" == "--all" ]]; then
    all=1
    shift
  fi

  local family dest updater os_id os_like
  IFS='|' read -r os_id os_like < <(detect_os_family)
  IFS='|' read -r family dest updater < <(ca_plan)

  printf "%bUninstalling root CA…%b\n" "$CYAN" "$NC"
  printf "%bDetected OS%b: id=%s like=%s → %s\n" "$CYAN" "$NC" "$os_id" "$os_like" "$family"

  local removed=0

  if [[ -e "$dest" ]]; then
    rm -f "$dest"
    removed=$((removed + 1))
    printf "%b✔ Removed%b → %s\n" "$GREEN" "$NC" "$dest"
  else
    printf "%bINFO%b: CA file not found at %s (nothing to remove)\n" "$YELLOW" "$NC" "$dest"
  fi

  if ((all)); then
    printf "%bScanning all known CA anchor paths…%b\n" "$CYAN" "$NC"
    local f
    for f in \
      "/usr/local/share/ca-certificates/${CA_BASENAME}.crt" \
      "/usr/local/share/ca-certificates/${CA_BASENAME}.pem" \
      "/etc/pki/ca-trust/source/anchors/${CA_BASENAME}.crt" \
      "/etc/pki/ca-trust/source/anchors/${CA_BASENAME}.pem" \
      "/etc/ca-certificates/trust-source/anchors/${CA_BASENAME}.crt" \
      "/etc/ca-certificates/trust-source/anchors/${CA_BASENAME}.pem"; do
      [[ "$f" == "$dest" ]] && continue
      if [[ -e "$f" ]]; then
        rm -f "$f"
        removed=$((removed + 1))
        printf "%b✔ Removed%b → %s\n" "$GREEN" "$NC" "$f"
      fi
    done
  fi

  case "$family" in
  debian | alpine)
    if has_cmd update-ca-certificates; then
      printf "%bUpdating trust store%b (update-ca-certificates)…\n" "$CYAN" "$NC"
      update-ca-certificates || printf "%bWARN%b: update-ca-certificates failed.\n" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: update-ca-certificates not found; trust store not refreshed.\n" "$YELLOW" "$NC" >&2
    fi

    if has_cmd trust; then
      printf "%bSyncing p11-kit%b (trust extract-compat)…\n" "$CYAN" "$NC"
      trust extract-compat >/dev/null 2>&1 || printf "%bWARN%b: trust extract-compat failed. Skipping.\n" "$YELLOW" "$NC" >&2
    fi
    ;;
  rhel)
    if has_cmd update-ca-trust; then
      printf "%bUpdating trust store%b (update-ca-trust extract)…\n" "$CYAN" "$NC"
      update-ca-trust extract || printf "%bWARN%b: update-ca-trust extract failed.\n" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: update-ca-trust not found; trust store not refreshed.\n" "$YELLOW" "$NC" >&2
    fi
    ;;
  arch)
    if has_cmd trust; then
      printf "%bUpdating trust store%b (trust extract-compat)…\n" "$CYAN" "$NC"
      trust extract-compat >/dev/null 2>&1 || printf "%bWARN%b: trust extract-compat failed.\n" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: 'trust' not found; trust store not refreshed.\n" "$YELLOW" "$NC" >&2
    fi
    ;;
  *)
    if has_cmd update-ca-certificates; then
      printf "%bUpdating trust store%b (update-ca-certificates)…\n" "$CYAN" "$NC"
      update-ca-certificates || true
    fi
    if has_cmd update-ca-trust; then
      printf "%bUpdating trust store%b (update-ca-trust extract)…\n" "$CYAN" "$NC"
      update-ca-trust extract || true
    fi
    if has_cmd trust; then
      printf "%bSyncing p11-kit%b (trust extract-compat)…\n" "$CYAN" "$NC"
      trust extract-compat >/dev/null 2>&1 || true
    fi
    printf "%bINFO%b: Unknown distro; removed CA file(s) if present. Refresh trust store manually if needed.\n" "$YELLOW" "$NC"
    ;;
  esac

  uninstall_ca_nss_user

  if ((removed)); then
    printf "%bRoot CA uninstalled%b (removed %d file(s))\n" "$GREEN" "$NC" "$removed"
  else
    printf "%bRoot CA already absent%b (no files removed)\n" "$YELLOW" "$NC"
  fi
}

add_required_env() {
  update_env "$ENV_DOCKER" WORKING_DIR "$DIR"
  ((EUID == 0)) && return 0
  update_env "$ENV_DOCKER" USER "$(id -un)"
  update_env "$ENV_DOCKER" UID "$(id -u)"
  update_env "$ENV_DOCKER" GID "$(id -g)"
}

###############################################################################
# Compose helpers for rebuild (robust: supports service key OR container name)
###############################################################################
__COMPOSE_CFG_JSON=""
__COMPOSE_CFG_YAML=""
__COMPOSE_SVCS_LOADED=0
declare -a __COMPOSE_SVCS=()

compose_cfg_json() {
  if [[ -z "${__COMPOSE_CFG_JSON}" ]]; then
    __COMPOSE_CFG_JSON="$(docker_compose config --format json 2>/dev/null || true)"
  fi
  printf '%s' "${__COMPOSE_CFG_JSON}"
}

compose_cfg_yaml() {
  if [[ -z "${__COMPOSE_CFG_YAML}" ]]; then
    __COMPOSE_CFG_YAML="$(docker_compose config 2>/dev/null || true)"
  fi
  printf '%s' "${__COMPOSE_CFG_YAML}"
}

compose_services_load() {
  ((__COMPOSE_SVCS_LOADED)) && return 0
  mapfile -t __COMPOSE_SVCS < <(docker_compose config --services 2>/dev/null || true)
  __COMPOSE_SVCS_LOADED=1
}

compose_service_exists() {
  local want="${1:-}" s
  [[ -n "$want" ]] || return 1
  compose_services_load
  for s in "${__COMPOSE_SVCS[@]}"; do
    [[ "$s" == "$want" ]] && return 0
  done
  return 1
}

resolve_service() {
  local raw="${1:-}" norm svc
  raw="${raw//[[:space:]]/}"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }

  compose_service_exists "$raw" && {
    printf '%s' "$raw"
    return 0
  }

  norm="$(normalize_service "$raw")"
  compose_service_exists "$norm" && {
    printf '%s' "$norm"
    return 0
  }

  if docker inspect "$raw" >/dev/null 2>&1; then
    svc="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$raw" 2>/dev/null || true)"
    if [[ -n "$svc" ]] && compose_service_exists "$svc"; then
      printf '%s' "$svc"
      return 0
    fi
  fi

  printf '%s' "$norm"
}

compose_has_build() {
  local svc="$1" json
  json="$(compose_cfg_json)"
  if [[ -n "$json" ]]; then
    if has_tool jq; then
      jq -e --arg s "$svc" '.services[$s].build != null' >/dev/null <<<"$json"
      return $?
    fi
  fi

  compose_cfg_yaml | awk -v s="$svc" '
    $1=="services:" {in_services=1; next}
    in_services && $0 ~ ("^  " s ":$") {in_svc=1; next}
    in_svc && $0 ~ /^  [A-Za-z0-9_.-]+:$/ {exit 1}
    in_svc && $0 ~ /^    build:/ {exit 0}
    END {exit 1}
  '
}

compose_image_for_service() {
  local svc="$1" json
  json="$(compose_cfg_json)"
  if [[ -n "$json" ]]; then
    if has_tool jq; then
      jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$json"
      return 0
    fi
  fi

  compose_cfg_yaml | awk -v s="$svc" '
    $1=="services:" {in_services=1; next}
    in_services && $0 ~ ("^  " s ":$") {in_svc=1; next}
    in_svc && $0 ~ /^  [A-Za-z0-9_.-]+:$/ {exit 0}
    in_svc && $0 ~ /^    image:/ {
      sub(/^    image:[[:space:]]*/, "", $0)
      print $0
      exit 0
    }
  '
}

###############################################################################
# 6. STACK COMMANDS (CLI)
###############################################################################

# One-time migration from the historical fixed 172.28/29/30 /24 networks.
# Only known LocalDevStack-owned networks are touched, and named volumes are
# never removed. New networks carry com.infocyph.network-schema=dynamic-v1.
declare -a __LDS_LEGACY_NETWORK_NAMES=(Frontend Backend DataStore)

legacy_network_expected_subnet() {
  case "\${1:-}" in
  Frontend) printf '%s' '172.28.0.0/24' ;;
  Backend) printf '%s' '172.29.0.0/24' ;;
  DataStore) printf '%s' '172.30.0.0/24' ;;
  *) return 1 ;;
  esac
}

migrate_legacy_networks() {
  local network expected subnets stack_label project_label schema_label ctr ctr_project attachments
  local -a legacy=()

  for network in "\${__LDS_LEGACY_NETWORK_NAMES[@]}"; do
    docker network inspect "$network" >/dev/null 2>&1 || continue

    schema_label="$(docker network inspect -f '{{index .Labels "com.infocyph.network-schema"}}' "$network" 2>/dev/null || true)"
    [[ "$schema_label" != "dynamic-v1" ]] || continue

    expected="$(legacy_network_expected_subnet "$network")"
    subnets="$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$network" 2>/dev/null || true)"
    grep -Fxq "$expected" <<<"$subnets" || continue

    stack_label="$(docker network inspect -f '{{index .Labels "com.infocyph.stack"}}' "$network" 2>/dev/null || true)"
    project_label="$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$network" 2>/dev/null || true)"
    if [[ "$stack_label" != "LocalDevStack" || "$project_label" != "LocalDevStack" ]]; then
      die "Legacy subnet detected on '$network', but ownership labels do not prove it belongs to LocalDevStack. Remove or rename that network manually."
    fi

    while IFS= read -r ctr; do
      [[ -n "$ctr" ]] || continue
      ctr_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$ctr" 2>/dev/null || true)"
      if [[ "$ctr_project" != "LocalDevStack" ]]; then
        die "Refusing to migrate '$network': container '$ctr' is not owned by the LocalDevStack Compose project."
      fi
    done < <(docker network inspect -f '{{range .Containers}}{{println .Name}}{{end}}' "$network" 2>/dev/null || true)

    legacy+=("$network")
  done

  (("\${#legacy[@]}" > 0)) || return 0

  warn "Legacy fixed LocalDevStack network(s) detected: \${legacy[*]}"
  warn "Recreating stack networks dynamically; named volumes and persisted data are preserved."

  # Stop/remove only LocalDevStack Compose containers and networks. Never use -v.
  docker_compose down --remove-orphans

  for network in "\${legacy[@]}"; do
    docker network inspect "$network" >/dev/null 2>&1 || continue
    attachments="$(docker network inspect -f '{{range .Containers}}{{println .Name}}{{end}}' "$network" 2>/dev/null || true)"
    [[ -z "$attachments" ]] ||
      die "Cannot remove legacy network '$network': attached container(s) remain: $(tr '\n' ' ' <<<"$attachments")"
    docker network rm "$network" >/dev/null
  done

  ok "Legacy fixed networks removed; Compose will recreate dynamic bridge networks."
}

cmd_vpn_fix() {
  warn "vpn-fix is deprecated: LocalDevStack no longer owns fixed Docker subnets."
  warn "If a VPN conflict remains after dynamic-network migration, diagnose the VPN/Docker route directly."
}

cmd_up() {
  migrate_legacy_networks
  dc_up "$@"
}

cmd_start() {
  migrate_legacy_networks
  dc_up -d "$@"
  http_reload
}

cmd_stop() { docker_compose down; }

cmd_down() {
  # Safety rails:
  #   lds down --volumes requires --yes
  local yes=0 vols=0
  local -a args=()
  while [[ "${1:-}" ]]; do
    case "$1" in
    --yes | -y)
      yes=1
      shift
      ;;
    --volumes | -v)
      vols=1
      args+=("--volumes")
      shift
      ;;
    --remove-orphans)
      args+=("--remove-orphans")
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
    esac
  done
  if ((vols)) && ((yes == 0)); then
    die "Refusing: down --volumes requires --yes"
  fi
  docker_compose down "${args[@]}"
}

cmd_restart() {
  cmd_stop
  cmd_start
}
cmd_reboot() { cmd_restart; }

# ─────────────────────────────────────────────────────────────────────────────
# 6a. STATUS / PS / STATS
# ─────────────────────────────────────────────────────────────────────────────
cmd_ps() {
  if (($#)); then
    docker_compose ps "$@"
  else
    docker_compose ps
  fi
}

cmd_status() {
  local ctr project
  project="$(lds_project)"
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container not found or not running for project: $project"

  local -a flags=()
  [[ -t 1 ]] && flags+=(-t)
  docker exec "${flags[@]}" "$ctr" status "$@"
}
# ─────────────────────────────────────────────────────────────────────────────
# 6b. LOGS / OPEN
# ─────────────────────────────────────────────────────────────────────────────
cmd_logs() {
  local svc="" follow=0 since="" grep_pat=""
  while [[ "${1:-}" ]]; do
    case "$1" in
    -f | --follow)
      follow=1
      shift
      ;;
    --since)
      since="${2:-}"
      shift 2
      ;;
    --grep)
      grep_pat="${2:-}"
      shift 2
      ;;
    *)
      svc="${1:-}"
      shift
      ;;
    esac
  done

  local -a args=()
  ((follow)) && args+=("-f")
  [[ -n "$since" ]] && args+=("--since" "$since")

  if [[ -n "$svc" ]]; then
    local s
    s="$(resolve_service "$svc" || true)"
    [[ -n "$s" ]] || die "Unknown service: $svc"
    if [[ -n "$grep_pat" ]]; then
      docker_compose logs "${args[@]}" "$s" 2>&1 | text_grep "$grep_pat"
    else
      docker_compose logs "${args[@]}" "$s"
    fi
  else
    if [[ -n "$grep_pat" ]]; then
      docker_compose logs "${args[@]}" 2>&1 | text_grep "$grep_pat"
    else
      docker_compose logs "${args[@]}"
    fi
  fi
}

cmd_open() {
  local target="${1:-}"
  [[ -n "$target" ]] || die "open <mail|db|redis|kibana|domain>"
  local url=""
  case "${target,,}" in
  mail | mailpit | webmail) url="https://webmail.localhost" ;;
  db | cloudbeaver) url="https://db.localhost" ;;
  redis | redisinsight | redis-insight | rds) url="http://ri.localhost" ;;
  mongo | me | mongoexpress | mongo-express) url="http://me.localhost" ;;
  kibana | kbn) url="http://kibana.localhost" ;;
  *)
    url="https://${target}"
    ;;
  esac
  open_url "$url"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6c. PROFILES
# ─────────────────────────────────────────────────────────────────────────────
_known_profile() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1

  # Prefer compose-config JSON for exact profile membership.
  local json
  json="$(compose_cfg_json)"
  if [[ -n "$json" ]] && has_tool jq; then
    printf '%s' "$json" | jq -e --arg p "$p" '
      [ .services[]? | (.profiles // [])[] ] | index($p) != null
    ' >/dev/null 2>&1
    return $?
  fi

  # Fallback: text scan when jq/json path is unavailable.
  local f
  for f in "$COMPOSE_FILE" "${__EXTRA_FILES[@]:-}"; do
    [[ -r "$f" ]] || continue
    grep -Fq -- "$p" "$f" && return 0
  done
  return 1
}

cmd_profiles() {
  local action="${1:-list}"
  shift || true
  case "${action,,}" in
  list | "")
    local cur=""
    [[ -r "$ENV_DOCKER" ]] && cur="$(grep -E '^COMPOSE_PROFILES=' "$ENV_DOCKER" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
    printf "%bEnabled profiles:%b %s
" "$CYAN" "$NC" "${cur:-<none>}"
    printf "%bAvailable profiles:%b
" "$CYAN" "$NC"
    printf '  - %s
' "${SERVICES[@]}" | LC_ALL=C sort -u
    # warn if enabled profile has no mention in compose
    if [[ -n "$cur" ]]; then
      local p
      IFS=',' read -r -a __ps <<<"$cur"
      for p in "${__ps[@]}"; do
        p="${p//[[:space:]]/}"
        [[ -n "$p" ]] || continue
        _known_profile "$p" || printf "%b[warn]%b enabled profile '%s' has no matching services in compose
" "$YELLOW" "$NC" "$p"
      done
    fi
    ;;
  add)
    [[ $# -gt 0 ]] || die "profiles add <profile...>"
    for p in "$@"; do
      modify_profiles add "$p"
    done
    ;;
  remove | rm | del)
    [[ $# -gt 0 ]] || die "profiles remove <profile...>"
    modify_profiles remove "$@"
    ;;
  *)
    die "profiles <list|add|remove>"
    ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# 6d. DIAG / SNIFF
# ─────────────────────────────────────────────────────────────────────────────
_tools_exec() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  # NOTE: pass a SINGLE command string; do not pass arrays here.
  docker exec -i "$ctr" sh -lc "$*"
}

_tools_exec_argv() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  local -a flags=(-i)
  [[ -t 0 && -t 1 ]] && flags+=(-t)
  docker exec "${flags[@]}" "$ctr" "$@"
}

cmd_ai() {
  local sub="${1:-status}"
  shift || true
  case "${sub,,}" in
  status | provider)
    _tools_exec_argv aiops provider "$@"
    ;;
  ask)
    _tools_exec_argv askai "$@"
    ;;
  explain | troubleshoot | review | repo-review | graphify)
    _tools_exec_argv aiops "${sub,,}" "$@"
    ;;
  *)
    die "ai <status|ask|explain|troubleshoot|review|repo-review|graphify> [args...]"
    ;;
  esac
}

_llm_exec() {
  local ctr
  ctr="$(docker_compose ps -q llm-sm 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$ctr" ]] || die "llm-sm is not running. Enable the ai profile and start the stack first."
  docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -qx true ||
    die "llm-sm container exists but is not running."

  local -a exec_args=(exec)
  [[ -t 0 && -t 1 ]] || exec_args+=(-T)
  docker_compose "${exec_args[@]}" llm-sm llm-sm "$@"
}

cmd_llm() {
  local sub="${1:-models}"
  shift || true

  case "${sub,,}" in
  runtime)
    local mode="${1:-}"
    if [[ -z "$mode" ]]; then
      printf '%s\n' "$(compose_control_value LDS_AI_RUNTIME cpu)"
      return 0
    fi
    case "${mode,,}" in
    cpu | nvidia | amd)
      update_env "$ENV_DOCKER" LDS_AI_RUNTIME "${mode,,}"
      ok "LLM runtime set to ${mode,,}. Recreate llm-sm to apply the change."
      ;;
    *) die "llm runtime <cpu|nvidia|amd>" ;;
    esac
    ;;
  host-port)
    local state="${1:-status}"
    case "${state,,}" in
    status)
      printf '%s\n' "$(compose_control_value LDS_LLM_HOST_PORT 0)"
      ;;
    on | enable | enabled | 1)
      update_env "$ENV_DOCKER" LDS_LLM_HOST_PORT 1
      ok "Direct LLM API enabled on loopback only. Recreate llm-sm to apply."
      ;;
    off | disable | disabled | 0)
      update_env "$ENV_DOCKER" LDS_LLM_HOST_PORT 0
      ok "Direct LLM host API disabled. Recreate llm-sm to apply."
      ;;
    *) die "llm host-port <status|on|off>" ;;
    esac
    ;;
  models | ps | show | pull | rm | unload | run | ask | chat | prompt | code | review | json | ai-commit | ollama | api | version)
    _llm_exec "${sub,,}" "$@"
    ;;
  help | -h | --help)
    printf '%s\n' "llm <models|ps|show|pull|rm|unload|run|ask|chat|prompt|code|review|json|ai-commit|ollama|api|version>"
    printf '%s\n' "llm runtime <cpu|nvidia|amd>"
    printf '%s\n' "llm host-port <status|on|off>"
    ;;
  *)
    die "llm <models|ps|show|pull|rm|unload|run|ask|chat|prompt|code|review|json|ai-commit|ollama|api|version|runtime|host-port>"
    ;;
  esac
}

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

# ─────────────────────────────────────────────────────────────────────────────
# 6e. SECRETS / CERT / HOST / UI
# ─────────────────────────────────────────────────────────────────────────────
cmd_secrets() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  docker exec -it "$ctr" senv "$@"
}

cmd_cert() {
  local ctr
  ctr="$(_project_tools_container_running || true)"
  [[ -n "$ctr" ]] || die "server-tools container is not running for project: $(lds_project)"
  docker exec -it "$ctr" certify "$@"
}

cmd_host() {
  local sub="${1:-}"
  shift || true
  case "${sub,,}" in
  add)
    setup_domain
    ;;
  rm | remove | del | delete)
    delete_domain "$@"
