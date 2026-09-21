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

    # Keep stdin attached even for pipes/here-strings. Only allocate a TTY when
    # both sides are interactive; proxied jq/rg/etc. must behave like host tools.
    local -a flags=(-i)
    [[ -t 0 && -t 1 ]] && flags+=(-t)
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
# RUN / MAINTENANCE
###############################################################################
# shellcheck source=lib/maintenance.sh
source "$DIR/lib/maintenance.sh"

# Extended stack/support diagnostics are loaded by lib/diagnostics.sh.

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
    die "stack <up|down|restart|status|ps|logs|exec|events|clean|config|diff|http>"
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
  trace) cmd_support_trace "$@" ;;
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
  local out=""
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

  # The archive is created from inside the temporary staging directory. Resolve
  # explicit relative destinations before changing directory so the final ZIP
  # survives staging cleanup.
  if [[ "$out" != /* ]]; then
    out="$PWD/${out#./}"
  fi

  {
    echo "project=$project"
    echo "dir=$DIR"
    echo "time=$ts"
    echo "mode=$mode"
  } >"$tmp/meta.txt"

  # compose config (effective). Redacted bundles must never contain interpolated
  # secrets from docker/.env.
  if [[ "$mode" == "redact" ]]; then
    {
      echo "# docker compose config"
      docker_compose config 2>&1 || true
    } | _redact_support_text >"$tmp/compose.config.txt"
  else
    {
      echo "# docker compose config"
      docker_compose config 2>&1 || true
    } >"$tmp/compose.config.txt"
  fi

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

  # recent logs (tail). Apply best-effort secret-pattern redaction in the
  # default shareable bundle.
  if [[ "$mode" == "redact" ]]; then
    docker_compose logs --no-color --tail 400 2>&1 | _redact_support_text >"$tmp/compose.logs.txt" || true
  else
    docker_compose logs --no-color --tail 400 >"$tmp/compose.logs.txt" 2>&1 || true
  fi

  # Generated vhosts live in Docker named volumes. Capture them through the
  # server-tools mount rather than stale host paths.
  local tools_ctr
  tools_ctr="$(_project_tools_container_running || true)"
  if [[ -n "$tools_ctr" ]]; then
    mkdir -p "$tmp/vhosts/nginx" "$tmp/vhosts/apache"
    docker cp "$tools_ctr:/etc/share/vhosts/nginx/." "$tmp/vhosts/nginx/" >/dev/null 2>&1 || true
    docker cp "$tools_ctr:/etc/share/vhosts/apache/." "$tmp/vhosts/apache/" >/dev/null 2>&1 || true
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

  # tools-side quick diagnostics (inside network). A support bundle remains
  # usable even when server-tools itself is down.
  if [[ -n "$tools_ctr" ]]; then
    {
      echo "# ip r / ip a / ss"
      docker exec -i "$tools_ctr" sh -lc 'ip r; echo; ip a; echo; ss -tulpen 2>/dev/null || true'
    } >"$tmp/tools.net.txt" 2>&1 || true
  else
    printf '%s\n' "server-tools is not running; in-container network diagnostics unavailable." >"$tmp/tools.net.txt"
  fi

  # pack
  if ! (cd "$tmp" && zip -qr "$out" .); then
    rm -rf "$tmp" 2>/dev/null || true
    die "Failed to write bundle: $out"
  fi
  rm -rf "$tmp" 2>/dev/null || true
  ok "Bundle created: $out"
}

cmd_help() {
  if [[ "${1:-}" == "--markdown" ]]; then
    cat <<'MD'
# LocalDevStack (lds) — Command Reference

## Global options
- `-v`, `--verbose`
- `-q`, `--quiet`
- `--reload-extras`
- `-h`, `--help`

## Stack
- `lds stack up` *(alias: `up`)*
- `lds stack start` *(alias: `start`)*
- `lds stack down [--volumes --yes]` *(aliases: `down`, `stop`)*
- `lds stack restart [service...]` *(aliases: `restart`, `reboot`)*
- `lds stack status [args...]` *(alias: `status`)*
- `lds stack ps` *(alias: `ps`)*
- `lds stack logs [service] [--follow] [--since <dur>] [--grep <pattern>]` *(alias: `logs`)*
- `lds stack exec <service> [cmd...]` *(alias: `exec`)*
- `lds stack events [since]` *(alias: `events`)*
- `lds stack clean --yes [--volumes] [--global]` *(alias: `clean`; scoped by default)*
- `lds stack diff [--config] [--json]`
- `lds stack config <show|services|profiles|env-used|validate>`
- `lds stack http reload`

## Domains
- `lds domain add`
- `lds domain rm [args...]`
- `lds domain ls`
- Legacy: `lds host add|rm|list`

## Setup and profiles
- `lds setup init|permissions|domain|profile|profiles`
- `lds profiles list`
- `lds profiles add <profile...>`
- `lds profiles remove <profile...>`

## Certificates
- `lds cert status [domain|all]`
- `lds cert regen [domain|all] [--yes]`
- `lds cert diagnose <domain>`
- `lds certificate install`
- `lds certificate uninstall [--all]`

## Diagnostics and support
- `lds doctor`
- `lds diag dns <domain>`
- `lds diag net`
- `lds diag tcp <host> <port>`
- `lds diag http <url> [curl-args...]`
- `lds diag tls <domain>`
- `lds sniff <url> [curl-args...]`
- `lds support open <admin|mail|db|redis|mongo|kibana|ai|domain>`
- `lds support trace <domain>`
- `lds support bundle [--redact|--full] [output.zip]`
- `lds support notify <watch|test> ...`
- `lds support ui`
- Shortcuts: `open`, `bundle`, `notify`, `ui`

## Config
- `lds config show [--json] [--raw]`
- `lds config services`
- `lds config profiles`
- `lds config env-used`
- `lds config validate`
- `lds images`
- `lds urls`

## Tools / shells / secrets
- `lds tools sh`
- `lds tools exec "<cmd>"`
- `lds tools file <path>`
- `lds cli <container> [cmd...]`
- `lds core [domain|container]`
- `lds secrets <senv-args...>`

## AI consumer
- `lds ai status|ask|explain|troubleshoot|review|repo-review|graphify ...`

## Host Graphify workflow
- `lds graphify [path] [graphify-extract-options...]`

## LLM provider
- `lds llm models|ps|show|pull|rm|unload|run|ask|chat|prompt|code|review|json|ai-commit|ollama|api|version ...`
- `lds llm runtime [cpu|nvidia|amd]`

## Rebuild
- `lds rebuild`
- `lds rebuild all`
- `lds rebuild <service...>`

## Ad-hoc Dockerfile runner
- `lds run`
- `lds run shell|ps|logs|stop|rm|open`
- flags: `--name`, `--tag`, `--no-build`, `--no-keepalive`, `--sock`, `--host-os`, `--publish|-p`, `--mount`, `--port`, `--path`, `--http`, `--https`

## Client/runtime wrappers
- PHP/Node: `php`, `composer`, `node`, `npm`, `npx`
- PostgreSQL: `pg`, `psql`, `pg_dump`, `pg_restore`
- MySQL: `my`, `mysql`, `mysqldump`
- MariaDB: `maria`, `mariadb`, `mariadb-dump`
- Redis: `redis`, `redis-cli`
- MongoDB: `mongo`, `mongodb`, `mongosh`, `mongoimport`, `mongoexport`
- Elasticsearch: `es`, `elastic`, `elasticsearch`

## Deprecated
- `lds vpn-fix` — fixed-subnet manipulation is no longer required.
MD
    return 0
  fi

  cat <<EOF
${BOLD}LocalDevStack (lds)${NC}

${CYAN}Global:${NC}
  -v|--verbose   -q|--quiet   --reload-extras   -h|--help

${CYAN}Stack:${NC}
  stack up|start|down|restart|status|ps|logs|exec|events|clean|config|diff|http
  up|start|down|stop|restart|reboot|status|ps|logs|exec|events
  clean --yes [--volumes] [--global]   (LocalDevStack-scoped unless --global)

${CYAN}Domains:${NC}
  domain add|rm|ls
  host add|rm|list                     Legacy aliases
  core [domain|container]
  cli <container> [cmd...]

${CYAN}Setup / Profiles:${NC}
  setup init|permissions|domain|profile|profiles
  profiles list|add|remove

${CYAN}Certificates:${NC}
  cert status|regen|diagnose
  certificate install|uninstall [--all]

${CYAN}Diagnostics / Support:${NC}
  doctor
  diag dns|net|tcp|http|tls
  sniff <url>
  support open <target>
  support trace <domain>
  support bundle [--redact|--full] [output.zip]
  support notify <watch|test> ...
  support ui
  open|bundle|notify|ui                 Shortcuts

${CYAN}Config:${NC}
  config show|services|profiles|env-used|validate
  images
  urls

${CYAN}Tools / Secrets:${NC}
  tools sh|exec|file
  secrets <senv-args...>

${CYAN}AI:${NC}
  ai status|ask|explain|troubleshoot|review|repo-review|graphify
  graphify [path] [graphify-extract-options...]
  llm models|ps|show|pull|rm|unload|run|ask|chat|prompt|code|review|json|ai-commit|ollama|api|version
  llm runtime [cpu|nvidia|amd]

${CYAN}Maintenance:${NC}
  rebuild [all|<service...>]
  run [shell|ps|logs|stop|rm|open] [runner flags...]

${CYAN}Wrappers:${NC}
  php|composer|node|npm|npx
  pg|psql|pg_dump|pg_restore
  my|mysql|mysqldump
  maria|mariadb|mariadb-dump
  redis|redis-cli
  mongo|mongodb|mongosh|mongoimport|mongoexport
  es|elastic|elasticsearch

${CYAN}Help:${NC}
  help
  help --markdown
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

  # Offline-safe read-only commands do not require a running Docker daemon.
  case "$cmd" in
  images | urls | doctor)
    ;;
  config)
    [[ "${1:-}" == "env-used" ]] || need docker
    ;;
  *)
    need docker
    ;;
  esac

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
