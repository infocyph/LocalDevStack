#!/usr/bin/env bash
# Force bash even if invoked via sh
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

# shellcheck disable=SC1090,SC2155

set -euo pipefail

###############################################################################
# 0. PATHS & CONSTANTS
###############################################################################
# Resolve script directory portably (Linux/macOS/WSL)
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

DIR="$(dirname -- "$(_realpath "$0")")"
CFG="$DIR/docker"
ENV_MAIN="$DIR/.env"
ENV_DOCKER="$CFG/.env"
COMPOSE_FILE="$CFG/compose/main.yaml"
EXTRAS_DIR="$CFG/extras"

if [[ "${1:-}" == "--__win_workdir" ]]; then
  export WORKDIR_WIN="${2:-}"
  shift 2
fi

COLOR() { printf '\033[%sm' "$1"; }
RED=$(COLOR '0;31') GREEN=$(COLOR '0;32') CYAN=$(COLOR '0;36')
YELLOW=$(COLOR '1;33') BLUE=$(COLOR '0;34') MAGENTA=$(COLOR '0;35')
NC=$(COLOR '0')

# Default behavior: QUIET
VERBOSE=0

#───────────────────────────────────────────────────────────────────────────────
# 0. GLOBAL ERROR HANDLER
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
  printf "\n%bError:%b '%s' failed at line %d (exit %d)\n\n" \
    "$RED" "$NC" "$3" "$2" "$1"
  exit "$1"
}

###############################################################################
# 1. COMMON HELPERS
###############################################################################
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

# ── compose extras (docker/extras/*.y{a,}ml) ────────────────────────────────
__EXTRAS_LOADED=0
declare -a __EXTRA_FILES=()

load_extras() {
  ((__EXTRAS_LOADED)) && return 0
  __EXTRAS_LOADED=1

  [[ -d "$EXTRAS_DIR" ]] || return 0

  # Stable ordering: later -f overrides earlier.
  mapfile -t __EXTRA_FILES < <(
    find "$EXTRAS_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
  )
}

docker_compose() {
  load_extras

  local -a files=()
  if ((${#__EXTRA_FILES[@]})); then
    local f
    for f in "${__EXTRA_FILES[@]}"; do
      files+=(-f "$f")
    done
  fi

  # Prefer Docker Compose v2 ("docker compose"), fallback to v1 ("docker-compose")
  local -a dc=(docker compose)
  if ! docker compose version >/dev/null 2>&1; then
    dc=(docker-compose)
  fi

  "${dc[@]}" \
    --project-directory "$DIR" \
    -f "$COMPOSE_FILE" \
    "${files[@]}" \
    --env-file "$ENV_DOCKER" \
    "$@"
}

# ── docker compose wrappers (QUIET by default) ────────────────────────────────
dc_up() {
  if ((VERBOSE)); then
    docker_compose up "$@"
  else
    docker_compose up --quiet-pull "$@"
  fi
}

dc_pull() {
  if ((VERBOSE)); then
    docker_compose pull "$@"
  else
    docker_compose pull -q "$@"
  fi
}

dc_build() {
  if ((VERBOSE)); then
    docker_compose build "$@"
  else
    docker_compose build --quiet "$@"
  fi
}

# helper for our own minimal logging (still shows in quiet mode)
logv() { ((VERBOSE)) && printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2 || true; }
logq() { printf "%b[%s]%b %s\n" "$CYAN" "${1:-info}" "$NC" "${2:-}" >&2; }

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

http_reload() {
  printf "%bReloading HTTP...%b" "$MAGENTA" "$NC"
  docker ps -qf name=NGINX &>/dev/null && docker exec NGINX nginx -s reload &>/dev/null || true
  docker ps -qf name=APACHE &>/dev/null && docker exec APACHE apachectl graceful &>/dev/null || true
  printf "\r%bHTTP reloaded!   %b\n" "$GREEN" "$NC"
}

###############################################################################
# 2. PERMISSIONS FIX-UP
###############################################################################
add_to_windows_path() {
  [[ "$OSTYPE" =~ (msys|cygwin) ]] || return 0
  command -v cygpath >/dev/null 2>&1 || return 0

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

  chmod 2777 "$DIR/data"
  mkdir -p "$DIR/data/cloudbeaver" "$DIR/data/mysql" "$DIR/data/postgresql" "$DIR/data/mongo" \
    "$DIR/data/mariadb" "$DIR/data/elasticsearch" "$DIR/data/redis" "$DIR/data/mailpit" \
    "$DIR/data/redis-insight" "$DIR/data/kibana"
  find "$DIR/data" -mindepth 1 -maxdepth 1 -type d -exec chmod 2777 {} +
  find "$DIR/data" -type f -exec chmod 666 {} +

  chmod -R 777 "$DIR/logs"
  chown -R "$USER:docker" "$DIR/logs"

  chmod 755 "$DIR/bin"
  find "$DIR/bin" -type f -exec chmod +x {} +
  chmod +x "$DIR/lds"

  ln -fs "$DIR/lds" /usr/local/bin/lds
  printf "%bPermissions assigned.%b\n" "$GREEN" "$NC"
}

###############################################################################
# 3. DOMAIN & PROFILE UTILITIES
###############################################################################
mkhost() { docker exec SERVER_TOOLS mkhost "$@"; }
delhost() { docker exec SERVER_TOOLS delhost "$@"; }

setup_domain() {
  mkhost --RESET
  docker exec -it SERVER_TOOLS mkhost
  local php_prof svr_prof node_prof
  php_prof=$(mkhost --ACTIVE_PHP_PROFILE || true)
  svr_prof=$(mkhost --APACHE_ACTIVE || true)
  node_prof=$(mkhost --ACTIVE_NODE_PROFILE || true)
  [[ -n $php_prof ]] && modify_profiles add "$php_prof"
  [[ -n $svr_prof ]] && modify_profiles add "$svr_prof"
  [[ -n $node_prof ]] && modify_profiles add "$node_prof"
  mkhost --RESET
  dc_up -d
  http_reload
}

cmd_delhost() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || die "Usage: lds delhost <domain>"

  delhost "$domain"
  delhost --RESET >/dev/null 2>&1 || true

  http_reload
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
  [elasticsearch]="ELASTICSEARCH_VERSION=9.2.4 ELASTICSEARCH_PORT=9200"
  [mysql]="MYSQL_VERSION=latest MYSQL_PORT=3306 MYSQL_ROOT_PASSWORD=12345 MYSQL_USER=infocyph MYSQL_PASSWORD=12345 MYSQL_DATABASE=localdb"
  [mariadb]="MARIADB_VERSION=latest MARIADB_PORT=3306 MARIADB_ROOT_PASSWORD=12345 MARIADB_USER=infocyph MARIADB_PASSWORD=12345 MARIADB_DATABASE=localdb"
  [mongodb]="MONGODB_VERSION=latest MONGODB_PORT=27017 MONGODB_ROOT_USERNAME=root MONGODB_ROOT_PASSWORD=12345"
  [redis]="REDIS_VERSION=latest REDIS_PORT=6379"
  [postgresql]="POSTGRES_VERSION=latest POSTGRES_PORT=5432 POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres POSTGRES_DATABASE=postgres"
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
# 4a. LAUNCH PHP CONTAINER INSIDE DOCROOT
###############################################################################
launch_php() {
  local domain=$1 suffix
  local nconf="$DIR/configuration/nginx/$domain.conf"
  local aconf="$DIR/configuration/apache/$domain.conf"
  [[ -f $nconf ]] || die "No Nginx config for $domain"

  local docroot php
  if grep -q fastcgi_pass "$nconf"; then
    php=$(grep -Eo 'fastcgi_pass ([^:]+):9000' "$nconf" | awk '{print $2}' | sed 's/:9000$//')
    docroot=$(grep -m1 -Eo 'root [^;]+' "$nconf" | awk '{print $2}')
  else
    [[ -f $aconf ]] || die "No Apache config for $domain"
    docroot=$(grep -m1 -Eo 'DocumentRoot [^ ]+' "$aconf" | awk '{print $2}')
    php=$(grep -Eo 'proxy:fcgi://([^:]+):9000' "$aconf" | sed 's/.*:\/\/\([^:]*\):.*/\1/')
  fi

  [[ $php ]] || die "Could not detect PHP container for $domain"
  [[ $docroot ]] || docroot=/app
  for suffix in public dist public_html; do
    [[ $docroot == */$suffix ]] && {
      docroot=${docroot%/*}
      break
    }
  done

  php=$(echo "$php" | tr ' \n' '\n' | awk 'NF && !seen[$0]++' | paste -sd' ' -)
  docker exec -it "$php" bash --login -c "cd '$docroot' && exec bash"
}

###############################################################################
# 4b. LAUNCH NODE CONTAINER (always /app)
###############################################################################
launch_node() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || die "Usage: lds core <domain>"

  local nconf="$DIR/configuration/nginx/$domain.conf"
  [[ -f "$nconf" ]] || die "No Nginx config for $domain"

  # Expect: proxy_pass http://node_<token>:<port>;
  local upstream host token ctr
  upstream="$(
    grep -m1 -Eo 'proxy_pass[[:space:]]+http://[^;]+' "$nconf" 2>/dev/null |
      awk '{print $2}' |
      sed 's|^http://||'
  )"

  [[ -n "${upstream:-}" ]] || die "Could not detect node upstream for $domain"
  host="${upstream%%:*}" # node_resume_sparkle_localhost

  [[ -n "${host:-}" ]] || die "Could not parse upstream host for $domain"

  # Standard mapping: node_<token> -> NODE_<TOKEN>
  ctr=""
  if docker inspect "$host" >/dev/null 2>&1; then
    ctr="$host"
  elif [[ "$host" == node_* ]]; then
    token="${host#node_}"
    ctr="NODE_${token^^}"
    docker inspect "$ctr" >/dev/null 2>&1 || ctr=""
  fi

  [[ -n "${ctr:-}" ]] || die "Node container not found for upstream '$host' (domain: $domain)"
  docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -qx true || die "Container not running: $ctr"

  docker exec -it "$ctr" sh -lc '
    cd /app 2>/dev/null || cd / || true
    if command -v bash >/dev/null 2>&1; then exec bash --login; fi
    exec sh
  '
}

conf_node_container() {
  local f="$1"

  # Nginx node vhost: proxy_pass http://node_<token>:<port>;
  local host token ctr

  host="$(
    grep -m1 -Eo 'proxy_pass[[:space:]]+http://[^;]+' "$f" 2>/dev/null |
      awk '{print $2}' |
      sed 's|^http://||' |
      awk -F: '{print $1}'
  )"

  [[ -n "${host:-}" ]] || return 0
  [[ "$host" == node_* ]] || return 0

  token="${host#node_}"
  ctr="NODE_${token^^}"

  docker inspect "$ctr" >/dev/null 2>&1 || return 0
  printf '%s' "$ctr"
}

###############################################################################
# 5. ENV + CERT
###############################################################################
detect_timezone() {
  if command -v timedatectl &>/dev/null; then
    timedatectl show -p Timezone --value
  elif [[ -n ${TZ-} ]]; then
    printf '%s' "$TZ"
  elif [[ -r /etc/timezone ]]; then
    </etc/timezone
  elif command -v powershell.exe &>/dev/null; then
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
  elif command -v uname >/dev/null 2>&1; then
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
    printf 'debian|/usr/local/share/ca-certificates/rootCA.crt|update-ca-certificates
'
    ;;
  *" alpine "*)
    printf 'alpine|/usr/local/share/ca-certificates/rootCA.crt|update-ca-certificates
'
    ;;
  *" fedora "* | *" rhel "* | *" redhat "* | *" centos "* | *" rocky "* | *" alma "* | *" amzn "* | *" amazon "* | *" sles "* | *" suse "*)
    printf 'rhel|/etc/pki/ca-trust/source/anchors/rootCA.crt|update-ca-trust
'
    ;;
  *" arch "* | *" manjaro "*)
    printf 'arch|/etc/ca-certificates/trust-source/anchors/rootCA.crt|trust
'
    ;;
  *)
    # best default: Debian-style location (works on many distros even if updater differs)
    printf 'fallback|/usr/local/share/ca-certificates/rootCA.crt|
'
    ;;
  esac
}

is_windows_shell() {
  [[ "${OSTYPE:-}" =~ (msys|cygwin) ]] || [[ -n "${WORKDIR_WIN:-}" ]]
}

need_windows_tools() {
  command -v cygpath >/dev/null 2>&1 || die "Windows certificate install needs 'cygpath' (Git Bash)."
  command -v powershell.exe >/dev/null 2>&1 || die "Windows certificate install needs 'powershell.exe' on PATH."
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

    \$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser')
    \$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

    \$exists = \$store.Certificates | Where-Object { \$_.Thumbprint -eq \$cert.Thumbprint }
    if (-not \$exists) { \$store.Add(\$cert) }

    \$store.Close()
  " >/dev/null 2>&1 || die "Windows certificate install failed (PowerShell import)."

  printf "%bRoot CA installed on Windows%b (CurrentUser\\Root)\n" "$GREEN" "$NC"
  printf "%bNote:%b restart browsers if they still show trust errors.\n" "$YELLOW" "$NC"
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

  printf "%bInstalling root CA…%b
" "$CYAN" "$NC"
  printf "%bDetected OS%b: id=%s like=%s → %s
" "$CYAN" "$NC" "$os_id" "$os_like" "$family"

  install -d -m 755 "$(dirname "$dest")"
  install -m 644 "$src_ca" "$dest"
  printf "%b✔ Copied%b → %s
" "$GREEN" "$NC" "$dest"

  case "$family" in
  debian | alpine)
    if command -v update-ca-certificates >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (update-ca-certificates)…\n" "$CYAN" "$NC"
      if update-ca-certificates; then
        printf "%b✔ Trust store updated%b
" "$GREEN" "$NC"
        printf "%bNote:%b If you see \"rehash: skipping ca-certificates.crt…\", that’s normal (it’s a bundle).
" "$YELLOW" "$NC"
      else
        printf "%bWARN%b: update-ca-certificates failed. CA is installed but may not be active yet.
" "$YELLOW" "$NC" >&2
      fi
    else
      printf "%bWARN%b: update-ca-certificates not found. CA is installed but auto-update is unavailable.
" "$YELLOW" "$NC" >&2
    fi

    # Optional p11-kit sync: best-effort only (can be missing helper on minimal installs)
    if command -v trust >/dev/null 2>&1; then
      printf "%bSyncing p11-kit%b (trust extract-compat)…\n" "$CYAN" "$NC"
      if trust extract-compat >/dev/null 2>&1; then
        printf "%b✔ p11-kit trust synced%b
" "$GREEN" "$NC"
      else
        printf "%bWARN%b: trust extract-compat failed (helper missing on some installs). Skipping.
" "$YELLOW" "$NC" >&2
      fi
    else
      printf "%bINFO%b: 'trust' not found — skipping p11-kit sync.
" "$YELLOW" "$NC"
    fi
    ;;
  rhel)
    if command -v update-ca-trust >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (update-ca-trust extract)…\n" "$CYAN" "$NC"
      if update-ca-trust extract; then
        printf "%b✔ Trust store updated%b
" "$GREEN" "$NC"
      else
        printf "%bWARN%b: update-ca-trust extract failed. CA is installed but may not be active yet.
" "$YELLOW" "$NC" >&2
      fi
    else
      printf "%bWARN%b: update-ca-trust not found. CA is installed but auto-update is unavailable.
" "$YELLOW" "$NC" >&2
    fi
    ;;
  arch)
    if command -v trust >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (trust extract-compat)…\n" "$CYAN" "$NC"
      if trust extract-compat >/dev/null 2>&1; then
        printf "%b✔ Trust store updated%b
" "$GREEN" "$NC"
      else
        printf "%bWARN%b: trust extract-compat failed. CA is installed, but trust sync may be incomplete.
" "$YELLOW" "$NC" >&2
      fi
    else
      printf "%bWARN%b: 'trust' not found. CA is installed, but trust sync is unavailable.
" "$YELLOW" "$NC" >&2
    fi
    ;;
  *)
    printf "%bINFO%b: Unknown distro; CA copied to %s.
" "$YELLOW" "$NC" "$dest"
    printf "%bINFO%b: You may need to update trust store manually for your OS.
" "$YELLOW" "$NC"
    ;;
  esac

  printf "%bRoot CA installed%b → %s
" "$GREEN" "$NC" "$dest"
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

  printf "%bUninstalling root CA…%b
" "$CYAN" "$NC"
  printf "%bDetected OS%b: id=%s like=%s → %s
" "$CYAN" "$NC" "$os_id" "$os_like" "$family"

  # Always remove the planned destination first
  local removed=0
  if [[ -e "$dest" ]]; then
    rm -f "$dest"
    removed=$((removed + 1))
    printf "%b✔ Removed%b → %s
" "$GREEN" "$NC" "$dest"
  else
    printf "%bINFO%b: CA file not found at %s (nothing to remove)
" "$YELLOW" "$NC" "$dest"
  fi

  # Optional: remove from all common anchor locations (for people who switched distros/paths)
  if ((all)); then
    printf "%bScanning all known CA anchor paths…%b
" "$CYAN" "$NC"
    local f
    for f in \
      /usr/local/share/ca-certificates/rootCA.crt \
      /usr/local/share/ca-certificates/rootCA.pem \
      /etc/pki/ca-trust/source/anchors/rootCA.crt \
      /etc/pki/ca-trust/source/anchors/rootCA.pem \
      /etc/ca-certificates/trust-source/anchors/rootCA.crt \
      /etc/ca-certificates/trust-source/anchors/rootCA.pem; do
      [[ "$f" == "$dest" ]] && continue
      if [[ -e "$f" ]]; then
        rm -f "$f"
        removed=$((removed + 1))
        printf "%b✔ Removed%b → %s
" "$GREEN" "$NC" "$f"
      fi
    done
  fi

  # Refresh trust store (best-effort, do not fail uninstall)
  case "$family" in
  debian | alpine)
    if command -v update-ca-certificates >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (update-ca-certificates)…\n" "$CYAN" "$NC"
      update-ca-certificates || printf "%bWARN%b: update-ca-certificates failed.
" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: update-ca-certificates not found; trust store not refreshed.
" "$YELLOW" "$NC" >&2
    fi

    # Optional p11-kit sync: best-effort only
    if command -v trust >/dev/null 2>&1; then
      printf "%bSyncing p11-kit%b (trust extract-compat)…\n" "$CYAN" "$NC"
      trust extract-compat >/dev/null 2>&1 || printf "%bWARN%b: trust extract-compat failed. Skipping.
" "$YELLOW" "$NC" >&2
    fi
    ;;
  rhel)
    if command -v update-ca-trust >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (update-ca-trust extract)…\n" "$CYAN" "$NC"
      update-ca-trust extract || printf "%bWARN%b: update-ca-trust extract failed.
" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: update-ca-trust not found; trust store not refreshed.
" "$YELLOW" "$NC" >&2
    fi
    ;;
  arch)
    if command -v trust >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (trust extract-compat)…\n" "$CYAN" "$NC"
      trust extract-compat >/dev/null 2>&1 || printf "%bWARN%b: trust extract-compat failed.
" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: 'trust' not found; trust store not refreshed.
" "$YELLOW" "$NC" >&2
    fi
    ;;
  *)
    # If unknown family, try what exists
    if command -v update-ca-certificates >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (update-ca-certificates)…\n" "$CYAN" "$NC"
      update-ca-certificates || true
    fi
    if command -v update-ca-trust >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (update-ca-trust extract)…\n" "$CYAN" "$NC"
      update-ca-trust extract || true
    fi
    if command -v trust >/dev/null 2>&1; then
      printf "%bSyncing p11-kit%b (trust extract-compat)…\n" "$CYAN" "$NC"
      trust extract-compat >/dev/null 2>&1 || true
    fi
    printf "%bINFO%b: Unknown distro; removed CA file(s) if present. Refresh trust store manually if needed.
" "$YELLOW" "$NC"
    ;;
  esac

  if ((removed)); then
    printf "%bRoot CA uninstalled%b (removed %d file(s))
" "$GREEN" "$NC" "$removed"
  else
    printf "%bRoot CA already absent%b (no files removed)
" "$YELLOW" "$NC"
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
    if command -v jq >/dev/null 2>&1; then
      jq -e --arg s "$svc" '.services[$s].build != null' >/dev/null <<<"$json"
      return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
      COMPOSE_CFG_JSON="$json" python3 - "$svc" <<'PY'
import json, os, sys
svc = sys.argv[1]
cfg = json.loads(os.environ.get("COMPOSE_CFG_JSON", "") or "{}")
sys.exit(0 if cfg.get("services", {}).get(svc, {}).get("build") is not None else 1)
PY
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
    if command -v jq >/dev/null 2>&1; then
      jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$json"
      return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
      COMPOSE_CFG_JSON="$json" python3 - "$svc" <<'PY'
import json, os, sys
svc = sys.argv[1]
cfg = json.loads(os.environ.get("COMPOSE_CFG_JSON", "") or "{}")
print(cfg.get("services", {}).get(svc, {}).get("image", "") or "")
PY
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
# 6. COMMANDS
###############################################################################
cmd_up() { dc_up "$@"; }

cmd_start() {
  dc_up -d "$@"
  http_reload
}

cmd_reload() { cmd_start "$@"; }
cmd_stop() { docker_compose down; }
cmd_down() { cmd_stop; }
cmd_restart() {
  cmd_stop
  cmd_start
}
cmd_reboot() { cmd_restart; }

normalize_service() {
  local raw="${1:-}"
  local s="${raw//[[:space:]]/}"
  [[ -n "$s" ]] || {
    printf '%s' ""
    return 0
  }

  local low="${s,,}"

  local key="${low//_/}"
  key="${key//-/}"
  if [[ "$key" =~ ^php ]]; then
    local ver="${key#php}"
    ver="${ver//[^0-9]/}"
    if [[ "$ver" =~ ^([0-9])([0-9]).* ]]; then
      printf 'php%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      return 0
    fi
    printf 'php'
    return 0
  fi

  low="${low//_/-}"
  while [[ "$low" == *"--"* ]]; do low="${low//--/-}"; done
  printf '%s' "$low"
}

cmd_rebuild() {
  local -a targets=() all_svcs=()
  local arg svc img
  declare -A seen=()

  # -----------------------------
  # helper: add a service once
  # -----------------------------
  _add_target() {
    local s="$1"
    [[ -n "$s" ]] || return 0
    [[ -n "${seen[$s]:-}" ]] && return 0
    seen[$s]=1
    targets+=("$s")
  }

  # -----------------------------
  # helper: trim
  # -----------------------------
  _trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
  }

  # -----------------------------
  # helper: interactive selection (comma separated, supports ranges)
  # accepts: "all" or "1,3,5-7" or mix with names "nginx,2,5-6"
  # -----------------------------
  _pick_targets_interactive() {
    mapfile -t all_svcs < <(docker_compose config --services 2>/dev/null)
    [[ ${#all_svcs[@]} -gt 0 ]] || die "No services found (docker compose config --services failed?)"

    echo
    echo "Select services to rebuild (comma separated; ranges allowed)."
    echo "Examples: 1,3,5-7   |   nginx,2,5-6   |   all"
    echo

    local i
    for i in "${!all_svcs[@]}"; do
      printf "  %2d) %s\n" "$((i + 1))" "${all_svcs[$i]}"
    done

    echo
    local sel
    read -r -p "Pick: " sel
    sel="$(_trim "${sel:-}")"
    [[ -n "$sel" ]] || die "No selection provided."

    if [[ "${sel,,}" == "all" ]]; then
      for svc in "${all_svcs[@]}"; do _add_target "$svc"; done
      return 0
    fi

    # split by comma
    local IFS=,
    for arg in $sel; do
      arg="$(_trim "$arg")"
      [[ -n "$arg" ]] || continue

      # range like 3-7
      if [[ "$arg" =~ ^[0-9]+-[0-9]+$ ]]; then
        local a b
        a="${arg%-*}"
        b="${arg#*-}"
        ((a >= 1)) || continue
        ((b >= 1)) || continue
        ((a <= b)) || {
          local t="$a"
          a="$b"
          b="$t"
        }

        local n
        for ((n = a; n <= b; n++)); do
          ((n >= 1 && n <= ${#all_svcs[@]})) || continue
          _add_target "${all_svcs[$((n - 1))]}"
        done
        continue
      fi

      # single index
      if [[ "$arg" =~ ^[0-9]+$ ]]; then
        local n="$arg"
        ((n >= 1 && n <= ${#all_svcs[@]})) || continue
        _add_target "${all_svcs[$((n - 1))]}"
        continue
      fi

      # treat as service/container name
      svc="$(resolve_service "$arg")"
      [[ -n "$svc" ]] && _add_target "$svc"
    done

    [[ ${#targets[@]} -gt 0 ]] || die "No valid services selected."
  }

  # -----------------------------
  # build target list
  # -----------------------------
  if (($# == 0)); then
    _pick_targets_interactive
  elif [[ "${1,,}" == "all" ]]; then
    mapfile -t targets < <(docker_compose config --services 2>/dev/null)
    [[ ${#targets[@]} -gt 0 ]] || die "No services found (docker compose config --services failed?)"
  else
    for arg in "$@"; do
      svc="$(resolve_service "$arg")"
      [[ -n "$svc" ]] || continue
      _add_target "$svc"
    done
    [[ ${#targets[@]} -gt 0 ]] || die "No valid services provided."
  fi

  # -----------------------------
  # rebuild each target
  # -----------------------------
  for svc in "${targets[@]}"; do
    [[ -n "$svc" ]] || continue
    compose_service_exists "$svc" || die "Unknown service/container: '$svc'"

    if compose_has_build "$svc"; then
      logq rebuild "build/recreate $svc"
      dc_build --no-cache --pull "$svc"
      dc_up -d --no-deps --force-recreate "$svc"
      continue
    fi

    img="$(compose_image_for_service "$svc")"
    logq rebuild "pull/recreate $svc${img:+ ($img)}"

    docker_compose rm -sf "$svc" >/dev/null 2>&1 || true

    if [[ -n "${img:-}" ]]; then
      docker rmi -f "$img" >/dev/null 2>&1 || true
      dc_pull "$svc" || true
    else
      dc_build --no-cache --pull "$svc" >/dev/null 2>&1 || true
    fi

    dc_up -d --no-deps --force-recreate "$svc"
  done
  dc_up -d
}

cmd_config() { docker_compose config; }

docker_shell() {
  local c="${1:-}"
  [[ -n "$c" ]] || die "container name required"
  if docker exec "$c" sh -lc 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
    exec docker exec -it "$c" bash
  else
    exec docker exec -it "$c" sh
  fi
}
cmd_tools() { docker_shell SERVER_TOOLS; }
cmd_lzd() { docker exec -it SERVER_TOOLS lazydocker; }
cmd_lazydocker() { cmd_lzd; }
cmd_http() { [[ ${1:-} == reload ]] && http_reload; }
cmd_cli() {
  local ctr="${1:-}"
  shift || true

  [[ -n "$ctr" ]] || die "Usage: lds cli <container> [cmd...]"

  docker inspect "$ctr" >/dev/null 2>&1 || die "Container not found: $ctr"
  docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -qx true || die "Container not running: $ctr"

  # If user provided a command, run it; otherwise open an interactive shell.
  if [[ "$#" -gt 0 ]]; then
    local cmd="$*"
    docker exec -it "$ctr" sh -lc '
      if command -v bash >/dev/null 2>&1; then
        exec bash --login -lc "$1"
      fi
      exec sh -lc "$1"
    ' sh "$cmd"
    return
  fi

  docker exec -it "$ctr" sh -lc '
    if command -v bash >/dev/null 2>&1; then
      exec bash --login
    fi
    exec sh
  '
}

cmd_core() {
  # Usage:
  #   lds core <domain>  -> open correct container for that domain (PHP/Node)
  #   lds core           -> list domains and let user pick

  local domain="${1:-}"
  if [[ -z "$domain" ]]; then
    # No domain supplied: show an indexed list so selection is explicit and reliable.
    domain="$(core_pick_domain)" || {
      local rc=$?
      ((rc == 130)) && return 130
      die "No domain selected"
    }
  fi

  local nconf="$DIR/configuration/nginx/$domain.conf"
  [[ -f "$nconf" ]] || die "No Nginx config for $domain"

  # Node vhost?
  if grep -Eq 'proxy_pass[[:space:]]+http://node_[A-Za-z0-9._-]+:[0-9]+' "$nconf"; then
    launch_node "$domain"
    return 0
  fi

  # Otherwise keep legacy PHP behavior
  launch_php "$domain"
  return 0
}

core_pick_domain() {
  local -a domains=()
  local f d

  shopt -s nullglob
  for f in "$DIR/configuration/nginx/"*.conf; do
    d="$(basename -- "$f" .conf)"
    [[ -n "$d" ]] && domains+=("$d")
  done
  shopt -u nullglob

  ((${#domains[@]} > 0)) || die "No domains found in $DIR/configuration/nginx"

  # stable ordering
  IFS=$'\n' domains=($(printf '%s\n' "${domains[@]}" | LC_ALL=C sort -u))

  # If there's only one domain, just use it.
  if ((${#domains[@]} == 1)); then
    printf '%s' "${domains[0]}"
    return 0
  fi

  # Must be interactive to pick.
  if [[ ! -t 0 ]]; then
    printf "%b[core]%b No domain provided. Available domains:\n" "$YELLOW" "$NC" >&2
    local i=1
    for d in "${domains[@]}"; do
      printf "  %2d) %s\n" "$i" "$d" >&2
      ((i++))
    done
    die "No TTY to prompt. Use: lds core <domain>"
  fi

  printf "%bSelect domain:%b\n" "$CYAN" "$NC" >&2
  local i=1
  for d in "${domains[@]}"; do
    printf "  %2d) %s\n" "$i" "$d" >&2
    ((i++))
  done
  printf "  %2d) %s\n" 0 "Cancel" >&2

  local ans idx
  while true; do
    printf "%bDomain #%b " "$GREEN" "$NC" >&2
    tty_readline ans "" || return 130
    ans="${ans//[[:space:]]/}"
    [[ -n "$ans" ]] || continue

    if [[ "$ans" == "0" ]]; then
      return 130
    fi

    if [[ "$ans" =~ ^[0-9]+$ ]]; then
      idx=$((ans - 1))
      if ((idx >= 0 && idx < ${#domains[@]})); then
        printf '%s' "${domains[$idx]}"
        return 0
      fi
    else
      # allow typing domain directly
      for d in "${domains[@]}"; do
        if [[ "$d" == "$ans" ]]; then
          printf '%s' "$d"
          return 0
        fi
      done
    fi

    printf "%bInvalid selection.%b\n" "$YELLOW" "$NC" >&2
  done
}

cmd_setup() {
  add_required_env
  case ${1:-} in
  init) env_init ;;
  permission | permissions | perms | perm) fix_perms ;;
  domain) setup_domain ;;
  profiles | profile) process_all ;;
  *) die "setup <init|permissions|domain|profiles>" ;;
  esac
}

cmd_certificate() {
  case ${1:-} in
  install)
    shift || true
    install_ca
    ;;
  uninstall | remove | rm)
    shift || true
    uninstall_ca "${@:-}"
    ;;
  *)
    die "certificate <install|uninstall [--all]>"
    ;;
  esac
}

cmd_doctor() {
  local os_id os_like
  IFS='|' read -r os_id os_like < <(detect_os_family)

  local is_win=0
  [[ "${OSTYPE:-}" =~ (msys|cygwin|win32) ]] && is_win=1

  printf "%bDoctor%b — environment checks\n" "$MAGENTA" "$NC"
  printf "%bOS%b: id=%s like=%s\n" "$CYAN" "$NC" "${os_id:-unknown}" "${os_like:-unknown}"
  ((is_win)) && printf "%bShell%b: Windows\n" "$CYAN" "$NC" || printf "%bShell%b: Unix\n" "$CYAN" "$NC"

  _ok() { printf "  %b✔%b %s\n" "$GREEN" "$NC" "$*"; }
  _warn() { printf "  %b!%b %s\n" "$YELLOW" "$NC" "$*"; }
  _bad() { printf "  %b✘%b %s\n" "$RED" "$NC" "$*"; }
  _has() { command -v "$1" >/dev/null 2>&1; }
  _first() {
    local c
    for c in "$@"; do _has "$c" && {
      echo "$c"
      return 0
    }; done
    return 1
  }

  # ────────────────────────────────────────────────────────────────────────────
  # TTY sanity (prompt/menus)
  # ────────────────────────────────────────────────────────────────────────────
  [[ -t 0 ]] && _ok "stdin: ok" || _warn "stdin: not a TTY"
  [[ -t 1 ]] && _ok "stdout: ok" || _warn "stdout: not a TTY"
  [[ -r /dev/tty ]] && _ok "tty: ok" || _warn "tty: not readable"

  # ────────────────────────────────────────────────────────────────────────────
  # Required base tools
  # ────────────────────────────────────────────────────────────────────────────
  local c
  for c in awk sed grep find sort; do
    _has "$c" && _ok "$c: ok" || _bad "$c: missing"
  done

  # ────────────────────────────────────────────────────────────────────────────
  # Windows essentials
  # ────────────────────────────────────────────────────────────────────────────
  if ((is_win)); then
    _has powershell.exe && _ok "powershell.exe: ok" || _bad "powershell.exe: missing"
    _has cygpath && _ok "cygpath: ok" || _bad "cygpath: missing"
    _has git.exe && _ok "git.exe: ok" || _warn "git.exe: missing"
    _has bash && _ok "bash: ok" || _bad "bash: missing"
  fi

  # ────────────────────────────────────────────────────────────────────────────
  # Docker CLI + daemon + context
  # ────────────────────────────────────────────────────────────────────────────
  local docker_cmd
  docker_cmd="$(_first docker docker.exe || true)"

  if [[ -n "$docker_cmd" ]]; then
    _ok "docker: $($docker_cmd --version 2>/dev/null || echo ok)"

    if $docker_cmd context show >/dev/null 2>&1; then
      _ok "docker context: $($docker_cmd context show 2>/dev/null)"
    else
      _warn "docker context: unavailable"
    fi

    if $docker_cmd info >/dev/null 2>&1; then
      _ok "docker daemon: ok"
    else
      _bad "docker daemon: not reachable"
      ((is_win)) && _warn "hint: start Docker Desktop; enable WSL2 engine"
    fi
  else
    _bad "docker: missing"
  fi

  # Compose presence (doctor should NOT print compose file path)
  if docker_compose version >/dev/null 2>&1; then
    _ok "compose: ok"
  else
    _bad "compose: missing"
  fi

  # Compose config validation (reuse your wrapper; keep quiet)
  if docker_compose config -q >/dev/null 2>&1; then
    _ok "compose config: ok"
  else
    _bad "compose config: invalid (run: lds config)"
  fi

  # ────────────────────────────────────────────────────────────────────────────
  # Optional tools (high-signal only)
  # ────────────────────────────────────────────────────────────────────────────
  _has openssl && _ok "openssl: ok" || _warn "openssl: missing"
  (_has wget || _has curl) && _ok "http client: ok" || _warn "http client: missing (curl/wget)"
  _has jq && _ok "jq: ok" || _warn "jq: missing"

  # ────────────────────────────────────────────────────────────────────────────
  # File/dir sanity (only show path when NOT ok)
  # ────────────────────────────────────────────────────────────────────────────
  [[ -f "$ENV_DOCKER" ]] && _ok "env: ok" || _warn "env: missing ($ENV_DOCKER)"
  [[ -d "$DIR/docker" ]] && _ok "docker dir: ok" || _bad "docker dir: missing ($DIR/docker)"
  [[ -d "$DIR/configuration" ]] && _ok "configuration dir: ok" || _bad "configuration dir: missing ($DIR/configuration)"
  [[ -d "$DIR/data" ]] && _ok "data dir: ok" || _warn "data dir: missing ($DIR/data)"
  [[ -d "$DIR/logs" ]] && _ok "logs dir: ok" || _warn "logs dir: missing ($DIR/logs)"

  # Writable checks (mount stability)
  if [[ -d "$DIR/data" ]]; then
    [[ -w "$DIR/data" ]] && _ok "data writable: ok" || _bad "data writable: no ($DIR/data)"
  fi
  if [[ -d "$DIR/logs" ]]; then
    [[ -w "$DIR/logs" ]] && _ok "logs writable: ok" || _bad "logs writable: no ($DIR/logs)"
  fi

  # Cert input (needed by your cert commands)
  [[ -f "$DIR/configuration/rootCA/rootCA.pem" ]] &&
    _ok "rootCA.pem: ok" ||
    _warn "rootCA.pem: missing ($DIR/configuration/rootCA/rootCA.pem)"

  # CRLF risk (bash scripts break)
  if [[ -f "$DIR/lds" ]]; then
    if grep -U $'\r' "$DIR/lds" >/dev/null 2>&1; then
      _warn "line endings: CRLF detected ($DIR/lds)"
    else
      _ok "line endings: ok"
    fi
  fi

  # ────────────────────────────────────────────────────────────────────────────
  # More checks (requested)
  # ────────────────────────────────────────────────────────────────────────────
  printf "\n%bMore checks%b\n" "$CYAN" "$NC"

  # Ports availability — only public ports: 80/443
  doctor_port_in_use() {
    local p="$1"
    if ((is_win)); then
      netstat -ano 2>/dev/null | awk '{print $2}' | grep -Eq ":${p}\$" && return 0 || return 1
    else
      if _has ss; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}\$" && return 0 || return 1
      elif _has lsof; then
        lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0 || return 1
      else
        return 2
      fi
    fi
  }

  local ports=(80 443)
  local any_unknown=0 p
  for p in "${ports[@]}"; do
    if doctor_port_in_use "$p"; then
      _warn "port $p: in use"
    else
      local rc=$?
      if [[ $rc -eq 2 ]]; then
        any_unknown=1
      else
        _ok "port $p: ok"
      fi
    fi
  done
  ((any_unknown)) && _warn "port scan: limited (install ss or lsof)"

  # Disk space (warn only if low)
  if df -Pk "$DIR" >/dev/null 2>&1; then
    local avail_kb
    avail_kb="$(df -Pk "$DIR" | awk 'NR==2{print $4}')"
    if [[ -n "$avail_kb" ]] && ((avail_kb < 5 * 1024 * 1024)); then
      _warn "disk: low (<5GiB free)"
    else
      _ok "disk: ok"
    fi
  else
    _warn "disk: unable to check"
  fi

  # WSL detection (Windows)
  if ((is_win)); then
    if _has wsl.exe; then
      if wsl.exe -l -q >/dev/null 2>&1; then
        _ok "WSL: ok"
      else
        _warn "WSL: present but not configured"
      fi
    else
      _warn "WSL: not found"
    fi
  fi

  # Compose profiles sanity (.env vs supported profiles)
  doctor_list_enabled_profiles() {
    [[ -f "$ENV_DOCKER" ]] || return 0
    local line
    line="$(grep -E '^(COMPOSE_PROFILES|PROFILES)=' "$ENV_DOCKER" 2>/dev/null | tail -n 1 || true)"
    [[ -n "$line" ]] || return 0
    line="${line#*=}"
    line="${line%\"}"
    line="${line#\"}"
    line="${line%\'}"
    line="${line#\'}"
    echo "$line" | tr ', ' '\n' | awk 'NF{print}'
  }

  local -A valid_profiles=()
  local key slug
  for key in "${SERVICE_ORDER[@]}"; do
    slug="${SERVICES[$key]}"
    [[ -n "$slug" ]] && valid_profiles["$slug"]=1
  done

  local seen_any=0 bad_any=0 prof
  while IFS= read -r prof; do
    [[ -n "$prof" ]] || continue
    seen_any=1
    if [[ -n "${valid_profiles[$prof]:-}" ]]; then
      _ok "profiles: '$prof' ok"
    else
      bad_any=1
      _warn "profiles: unknown '$prof'"
    fi
  done < <(doctor_list_enabled_profiles || true)

  ((seen_any == 0)) && _warn "profiles: none set (COMPOSE_PROFILES=...)"
  ((bad_any)) && _warn "profiles: sync COMPOSE_PROFILES with supported services"

  # ────────────────────────────────────────────────────────────────────────────
  # Tips
  # ────────────────────────────────────────────────────────────────────────────
  printf "\n%bTips%b\n" "$CYAN" "$NC"
  printf "  - Use: %blds certificate uninstall --all%b if you switched distros/paths.\n" "$BLUE" "$NC"
  printf "  - Use: %blds config%b to inspect full resolved compose config.\n" "$BLUE" "$NC"

  # ────────────────────────────────────────────────────────────────────────────
  # Install hints (bottom)
  # ────────────────────────────────────────────────────────────────────────────
  printf "\n%bInstall hints%b\n" "$CYAN" "$NC"

  if ((is_win)); then
    printf "  - Install Docker Desktop (WSL2 engine recommended)\n"
    printf "  - Install Git for Windows (Git Bash)\n"
    printf "  - Ensure docker.exe is on PATH and Docker Desktop is running\n"
    printf "  - (Optional) Install WSL: wsl --install\n"
  elif _has apt-get; then
    printf "  - Debian/Ubuntu:\n"
    printf "      sudo apt-get update && sudo apt-get install -y ca-certificates curl wget openssl p11-kit jq\n"
    printf "      sudo apt-get install -y docker-compose-plugin\n"
  elif _has dnf; then
    printf "  - Fedora/RHEL (dnf):\n"
    printf "      sudo dnf install -y ca-certificates curl wget openssl p11-kit-trust jq\n"
  elif _has yum; then
    printf "  - RHEL/CentOS (yum):\n"
    printf "      sudo yum install -y ca-certificates curl wget openssl p11-kit-trust jq\n"
  elif _has pacman; then
    printf "  - Arch:\n"
    printf "      sudo pacman -Syu --noconfirm ca-certificates curl wget openssl p11-kit jq\n"
  elif _has apk; then
    printf "  - Alpine:\n"
    printf "      sudo apk add --no-cache ca-certificates curl wget openssl p11-kit jq\n"
    printf "      sudo update-ca-certificates\n"
  elif _has zypper; then
    printf "  - SUSE:\n"
    printf "      sudo zypper install -y ca-certificates curl wget openssl p11-kit jq\n"
  else
    printf "  - Install: docker + compose + ca-certificates + openssl + p11-kit (+ jq optional)\n"
  fi

  # Extra feature: show quick “where to go next” suggestion only if env missing
  [[ -f "$ENV_DOCKER" ]] || _warn "next: run 'lds setup init' to generate env defaults"
}

###############################################################################
# NOTIFY
###############################################################################
notify_watch() {
  local container="${1:-SERVER_TOOLS}"
  local prefix="__HOST_NOTIFY__"

  need docker

  local _disp="${DISPLAY-}"
  local _dbus="${DBUS_SESSION_BUS_ADDRESS-}"

  # Args: timeout(ms) urgency title body
  _host_notify() {
    local timeout="${1:-2500}" urgency="${2:-normal}" title="${3:-Notification}" body="${4:-}"

    # Linux desktop (or WSLg)
    if command -v notify-send >/dev/null 2>&1; then
      (env DISPLAY="${_disp-}" DBUS_SESSION_BUS_ADDRESS="${_dbus-}" \
        setsid -f notify-send -u "$urgency" -t "$timeout" "$title" "$body" \
        >/dev/null 2>&1 || true) &
      return 0
    fi

    # Windows toast (Git Bash) / WSL-on-Windows
    if command -v powershell.exe >/dev/null 2>&1; then
      # Pass values as args to avoid quoting issues entirely.
      # Note: urgency/timeout not used by toast api here; kept for parity.
      powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
        'param([string]$t,[string]$b)
          try {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null

            function Esc([string]$s) {
              if ($null -eq $s) { return "" }
              return ($s -replace "&","&amp;" -replace "<","&lt;" -replace ">","&gt;" -replace "\"","&quot;" -replace "'\''","&apos;")
            }

            $title = Esc $t
            $body  = Esc $b

            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$title</text><text>$body</text></binding></visual></toast>")
            $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Devtainer").Show($toast)
          } catch { }' \
        --% "$title" "$body" >/dev/null 2>&1 || true

      return 0
    fi

    # Fallback
    printf "%s [%s] %s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$urgency" "$title" "$body" >&2
    return 0
  }

  trap - ERR
  set +e
  set +o pipefail

  local _stop=0

  _watcher_notify() {
    local urgency="${1:-critical}" title="${2:-Notifier}" body="${3:-Watcher event}"
    _host_notify 2500 "$urgency" "$title" "$body"
  }

  _watcher_int_term() {
    _stop=1
    _watcher_notify critical "Notifier" "Notification watcher interrupted/exiting"
    printf "%b[watcher]%b Notification watcher interrupted/exiting\n" "$RED" "$NC" >&2
  }
  trap _watcher_int_term INT TERM

  local grep_cmd=(grep -a --line-buffered -E "^${prefix}([[:space:]]|$)")
  command -v stdbuf >/dev/null 2>&1 && grep_cmd=(stdbuf -oL -eL "${grep_cmd[@]}")

  printf "%bNotify Watch:%b monitoring is active. Ctrl+C to stop.\n" "$GREEN" "$NC"

  while ((_stop == 0)); do
    if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
      _watcher_notify critical "Notifier" "Watcher stopped: $container is not running"
      printf "%b[watcher]%b %s is not running; exiting.\n" "$RED" "$NC" "$container" >&2
      break
    fi

    docker logs -f --tail 0 "$container" 2>&1 |
      ("${grep_cmd[@]}" || true) |
      while IFS=$'\t' read -r _ f1 f2 f3 f4 rest; do
        local timeout urgency title body

        if [[ "${f1:-}" =~ ^[0-9]{1,6}$ ]]; then
          timeout="$f1"
          urgency="${f2:-normal}"
          title="${f3:-Notification}"
          body="${f4:-}"
        else
          timeout="2500"
          urgency="${f1:-normal}"
          title="${f2:-Notification}"
          body="${f3:-}"
        fi

        [[ -n "${rest:-}" ]] && body+=$'\t'"${rest}"
        case "$urgency" in low | normal | critical) ;; *) urgency="normal" ;; esac

        _host_notify "$timeout" "$urgency" "$title" "$body"
        printf "%s [%s] %s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$urgency" "$title" "$body" >&2
      done

    ((_stop)) && break

    if docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
      _watcher_notify critical "Notifier" "Watcher lost log stream (docker logs ended). Reconnecting…"
      printf "%b[watcher]%b docker logs ended; reconnecting...\n" "$YELLOW" "$NC" >&2
      sleep 1
      continue
    fi

    _watcher_notify critical "Notifier" "Watcher stopped: $container stopped"
    printf "%b[watcher]%b %s stopped; exiting.\n" "$RED" "$NC" "$container" >&2
    break
  done

  trap - INT TERM
  set -euo pipefail

  ((_stop)) && return 130
  return 0
}

notify_test() {
  local title="${1:-Notifier OK}"
  local body="${2:-Hello from host via SERVER_TOOLS}"
  docker exec SERVER_TOOLS notify -t 2500 -u normal "$title" "$body"
}

cmd_notify() {
  case ${1:-watch} in
  watch) notify_watch "${2:-SERVER_TOOLS}" ;;
  test) notify_test "${2:-Notifier OK}" "${3:-Hello from host}" ;;
  *) die "notify <watch [container]|test \"Title\" \"Body\">" ;;
  esac
}

open_url() {
  local url="${1:-}"
  [[ -n "$url" ]] || return 0

  # WSL/Windows helpers first when available
  if grep -qi microsoft /proc/version 2>/dev/null; then
    if command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 || true
      return 0
    fi
    if command -v cmd.exe >/dev/null 2>&1; then
      cmd.exe /c start "" "$url" >/dev/null 2>&1 || true
      return 0
    fi
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    (xdg-open "$url" >/dev/null 2>&1 &)
    return 0
  fi
  if command -v open >/dev/null 2>&1; then
    (open "$url" >/dev/null 2>&1 &)
    return 0
  fi
  if command -v powershell >/dev/null 2>&1; then
    (powershell -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 &)
    return 0
  fi

  printf "%bINFO%b: open this URL manually → %s\n" "$YELLOW" "$NC" "$url"
}

###############################################################################
# RUN (ad-hoc Dockerfile runner)
###############################################################################
hash_short() {
  local s="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha1sum | cut -c1-8
  elif command -v shasum >/dev/null 2>&1; then
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

run_find_container() {
  local dir="$1"
  docker ps -a --filter "label=com.infocyph.lds.run=1" \
    --filter "label=com.infocyph.lds.dir=${dir}" \
    --format '{{.Names}}' | head -n 1
}

run_build() {
  local tag="$1" dir="$2"
  printf "%b[run]%b Building image %b%s%b from %s\n" "$CYAN" "$NC" "$BLUE" "$tag" "$NC" "$dir"
  docker build -t "$tag" "$dir"
}

run_start() {
  local name="$1" tag="$2" dir="$3" keepalive="$4" sock="$5"
  shift 5 || true

  local -a args=(docker run -d --name "$name"
    --label "com.infocyph.lds.run=1"
    --label "com.infocyph.lds.dir=$dir"
    --label "com.infocyph.lds.tag=$tag"
    -w /workspace
    -v "$dir:/workspace"
  )

  # Optional: allow containers to talk to Docker (DinD via host socket)
  if [[ "${sock:-0}" == 1 ]]; then
    [[ -S /var/run/docker.sock ]] || printf "%b[run]%b Warning: /var/run/docker.sock not found on host, mount may fail.\n" "$YELLOW" "$NC" >&2
    args+=(-v "/var/run/docker.sock:/var/run/docker.sock")
  fi

  # Publish ports: pass multiple --publish/-p flags from cmd_run
  local pub
  for pub in "$@"; do
    [[ -n "$pub" ]] || continue
    args+=(-p "$pub")
  done

  if [[ "$keepalive" == 1 ]]; then
    # keep container alive even if image CMD exits (good for "exec bash" workflow)
    args+=(--entrypoint sh "$tag" -c "trap : TERM INT; sleep infinity & wait")
  else
    args+=("$tag")
  fi

  printf "%b[run]%b Starting container %b%s%b
" "$CYAN" "$NC" "$BLUE" "$name" "$NC"
  "${args[@]}" >/dev/null
}

run_exec_shell() {
  local name="$1"
  if docker exec "$name" sh -lc 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
    exec docker exec -it "$name" bash
  else
    exec docker exec -it "$name" sh
  fi
}

cmd_vpn-fix() {
  set -euo pipefail

  local dry_run=0 rollback=0
  case "${1:-}" in
  --dry-run)
    dry_run=1
    shift || true
    ;;
  --rollback)
    rollback=1
    shift || true
    ;;
  esac

  local SUDO=""
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || {
      echo "Error: need root or sudo"
      return 1
    }
    SUDO="sudo"
  fi

  command -v ip >/dev/null 2>&1 || {
    echo "Error: ip not found"
    return 1
  }
  command -v iptables >/dev/null 2>&1 || {
    echo "Error: iptables not found"
    return 1
  }

  _run() {
    if ((dry_run)); then
      printf '[dry-run] %q ' "$@"
      echo
    else
      "$@"
    fi
  }

  # ---------------------------
  # Detect docker bridges (docker0 + br-*)
  # ---------------------------
  local br_ifs=()
  while IFS= read -r ifc; do br_ifs+=("$ifc"); done < <(
    ip -br link 2>/dev/null |
      awk '$1 ~ /^(docker0|br-[0-9a-f]{12})$/ {print $1}' |
      LC_ALL=C sort -u || true
  )

  if ((${#br_ifs[@]} == 0)); then
    echo "No docker bridge interfaces found (docker0 / br-*)."
    return 3
  fi

  # ---------------------------
  # Find default-route interface (exclude it from VPN candidates)
  # ---------------------------
  local def_if=""
  def_if="$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"

  # ---------------------------
  # Detect VPN interfaces
  #   - Do NOT rely on state column (UNKNOWN is common for tun)
  #   - Instead, require flags contain UP: "<...UP...>"
  # ---------------------------
  local vpn_ifs=()

  # A) Name-based (preferred)
  while IFS= read -r ifc; do
    [[ -n "$ifc" ]] || continue
    [[ "$ifc" == "$def_if" ]] && continue
    vpn_ifs+=("$ifc")
  done < <(
    ip -o link show 2>/dev/null |
      awk -F': ' '
        /<[^>]*UP[^>]*>/ {
          # field after ": " begins with interface name (may include "@ifX")
          split($2, a, " "); name=a[1]
          sub(/@.*/, "", name)
          print name
        }' |
      grep -E '^(tun|tap|wg|ppp|cscotun|utun|tailscale|zt|nordlynx|proton|vpn)[0-9]*$' |
      LC_ALL=C sort -u || true
  )

  # B) Route-based fallback (only if A found nothing)
  if ((${#vpn_ifs[@]} == 0)); then
    local -a cand=()
    while IFS= read -r ifc; do cand+=("$ifc"); done < <(
      ip -4 route show 2>/dev/null |
        awk '
          $1 ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)/ {
            for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); break}
          }' |
        LC_ALL=C sort -u |
        # exclude obvious non-vpn
        grep -Ev '^(lo|docker0|br-[0-9a-f]{12}|veth|lxcbr0)$' || true
    )

    local ifc
    for ifc in "${cand[@]:-}"; do
      [[ -n "$ifc" ]] || continue
      [[ "$ifc" == "$def_if" ]] && continue
      # ensure flags contain UP (don’t care about state)
      if ip -o link show "$ifc" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
        vpn_ifs+=("$ifc")
      fi
    done

    # de-dupe
    if ((${#vpn_ifs[@]})); then
      mapfile -t vpn_ifs < <(printf '%s\n' "${vpn_ifs[@]}" | LC_ALL=C sort -u)
    fi
  fi

  if ((${#vpn_ifs[@]} == 0)); then
    echo "No VPN interface detected."
    echo "Tip: connect VPN, then run: ip -o link show | grep -E '<.*UP.*>'"
    return 2
  fi

  # ---------------------------
  # IPv4 forwarding
  # ---------------------------
  if [[ -r /proc/sys/net/ipv4/ip_forward ]]; then
    local ipf
    ipf="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
    if [[ "$ipf" != "1" ]]; then
      _run $SUDO sysctl -w net.ipv4.ip_forward=1 >/dev/null
    fi
  fi

  local TAG="lds:vpn-fix"

  _ipt_append_if_missing() {
    local table="$1"
    shift
    local chain="$1"
    shift
    if _run $SUDO iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
      return 0
    fi
    _run $SUDO iptables -t "$table" -A "$chain" "$@"
  }

  _ipt_delete_if_present() {
    local table="$1"
    shift
    local chain="$1"
    shift
    if $SUDO iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
      _run $SUDO iptables -t "$table" -D "$chain" "$@"
    fi
  }

  local vpnif brif subnet
  for vpnif in "${vpn_ifs[@]}"; do
    local -a subnets=()
    while IFS= read -r subnet; do
      [[ -n "$subnet" ]] && subnets+=("$subnet")
    done < <(
      ip -4 route show dev "$vpnif" 2>/dev/null |
        awk '{print $1}' |
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' |
        LC_ALL=C sort -u || true
    )

    if ((${#subnets[@]} == 0)); then
      echo "Warning: $vpnif has no IPv4 routed subnets; skipping scoped rules."
      continue
    fi

    for subnet in "${subnets[@]}"; do
      if ((rollback)); then
        _ipt_delete_if_present nat POSTROUTING -o "$vpnif" -d "$subnet" -j MASQUERADE -m comment --comment "$TAG"
      else
        _ipt_append_if_missing nat POSTROUTING -o "$vpnif" -d "$subnet" -j MASQUERADE -m comment --comment "$TAG"
      fi

      for brif in "${br_ifs[@]}"; do
        if ((rollback)); then
          _ipt_delete_if_present filter FORWARD -i "$brif" -o "$vpnif" -d "$subnet" -j ACCEPT -m comment --comment "$TAG"
          _ipt_delete_if_present filter FORWARD -i "$vpnif" -o "$brif" -s "$subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$TAG"
        else
          _ipt_append_if_missing filter FORWARD -i "$brif" -o "$vpnif" -d "$subnet" -j ACCEPT -m comment --comment "$TAG"
          _ipt_append_if_missing filter FORWARD -i "$vpnif" -o "$brif" -s "$subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$TAG"
        fi
      done
    done
  done

  # ---------------------------
  # IPv6 (best-effort, scoped; skip if not actually in use)
  # ---------------------------
  if command -v ip6tables >/dev/null 2>&1; then
    local docker_has_v6=0 vpn_has_v6=0

    for brif in "${br_ifs[@]}"; do
      if ip -o -6 addr show dev "$brif" 2>/dev/null | grep -q 'inet6 '; then
        docker_has_v6=1
        break
      fi
    done

    for vpnif in "${vpn_ifs[@]}"; do
      if ip -o -6 addr show dev "$vpnif" 2>/dev/null | grep -q 'inet6 '; then
        vpn_has_v6=1
        break
      fi
    done

    if ((docker_has_v6 && vpn_has_v6)); then
      if [[ -r /proc/sys/net/ipv6/conf/all/forwarding ]]; then
        local ip6f
        ip6f="$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)"
        if [[ "$ip6f" != "1" ]]; then
          _run $SUDO sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
        fi
      fi

      _ip6t_append_if_missing() {
        local table="$1"
        shift
        local chain="$1"
        shift
        if _run $SUDO ip6tables -t "$table" -C "$chain" "$@" 2>/dev/null; then
          return 0
        fi
        _run $SUDO ip6tables -t "$table" -A "$chain" "$@"
      }

      _ip6t_delete_if_present() {
        local table="$1"
        shift
        local chain="$1"
        shift
        if $SUDO ip6tables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
          _run $SUDO ip6tables -t "$table" -D "$chain" "$@"
        fi
      }

      local v6subnet
      for vpnif in "${vpn_ifs[@]}"; do
        local -a v6subnets=()
        while IFS= read -r v6subnet; do
          [[ -n "$v6subnet" ]] && v6subnets+=("$v6subnet")
        done < <(
          ip -6 route show dev "$vpnif" 2>/dev/null |
            awk '{print $1}' |
            grep -E '^[0-9a-fA-F:]+/[0-9]+$' |
            LC_ALL=C sort -u || true
        )

        ((${#v6subnets[@]})) || {
          echo "IPv6: $vpnif has no routed IPv6 subnets; skipped."
          continue
        }

        for v6subnet in "${v6subnets[@]}"; do
          for brif in "${br_ifs[@]}"; do
            if ((rollback)); then
              _ip6t_delete_if_present filter FORWARD -i "$brif" -o "$vpnif" -d "$v6subnet" -j ACCEPT -m comment --comment "$TAG"
              _ip6t_delete_if_present filter FORWARD -i "$vpnif" -o "$brif" -s "$v6subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$TAG"
            else
              _ip6t_append_if_missing filter FORWARD -i "$brif" -o "$vpnif" -d "$v6subnet" -j ACCEPT -m comment --comment "$TAG"
              _ip6t_append_if_missing filter FORWARD -i "$vpnif" -o "$brif" -s "$v6subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$TAG"
            fi
          done

          if $SUDO ip6tables -t nat -L >/dev/null 2>&1; then
            if ((rollback)); then
              _ip6t_delete_if_present nat POSTROUTING -o "$vpnif" -d "$v6subnet" -j MASQUERADE -m comment --comment "$TAG"
            else
              _ip6t_append_if_missing nat POSTROUTING -o "$vpnif" -d "$v6subnet" -j MASQUERADE -m comment --comment "$TAG"
            fi
          fi
        done
      done
    else
      echo "IPv6: skipped (Docker bridges or VPN interface have no IPv6 addresses)."
    fi
  else
    echo "IPv6: skipped (ip6tables not installed)."
  fi

  if ((rollback)); then
    echo "OK: vpn-fix rolled back ($TAG)."
  else
    echo "OK: vpn-fix applied ($TAG)."
    echo "VPN interfaces: ${vpn_ifs[*]}"
    echo "Docker bridges: ${br_ifs[*]}"
    ((dry_run)) && echo "Note: dry-run mode, nothing changed."
  fi
}

cmd_run() {
  # Usage:
  #   lds run                          # build+start+exec for current directory
  #   lds run stop                     # stop container for current directory
  #   lds run rm                       # remove container (and image tag) for current directory
  #   lds run ps                       # list run containers
  #   lds run logs                     # follow logs for current directory container
  #   lds run open [--port P]          # open first published port (or P) in browser
  #
  # Flags:
  #   --dir PATH                          # run from another directory
  #   --name NAME                         # container name override
  #   --tag TAG                           # image tag override
  #   --no-build                          # do not build
  #   --no-keepalive                      # run image's default CMD/ENTRYPOINT
  #   --sock                              # mount docker sock: /var/run/docker.sock
  #   -p|--publish HOST:CONT              # publish port (repeatable)
  #   --port CONT_PORT                    # for 'open': choose container port
  #   --path /some/path                   # for 'open': default /
  #   --https                             # for 'open': use https
  local action="shell" dir="$PWD" name="" tag="" nobuild=0 keepalive=1 sock=0
  local -a publish=()
  local open_port="" open_path="/" open_proto="http"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    stop | rm | ps | shell | logs | open)
      action="$1"
      shift
      ;;
    --dir)
      dir="${2:-}"
      shift 2
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
    -p | --publish)
      publish+=("${2:-}")
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

  dir="$(cd "$dir" && pwd)"
  IFS='|' read -r def_name def_tag _def_dir < <(run_plan "$dir")
  name="${name:-$def_name}"
  tag="${tag:-$def_tag}"

  # Helper to locate "the" container for a dir
  _find_for_dir() {
    local found
    found="$(run_find_container "$dir" || true)"
    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return 0
    fi
    # fallback to explicit name if present
    if docker inspect "$name" >/dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
    return 1
  }

  case "$action" in
  ps)
    docker ps -a --filter "label=com.infocyph.lds.run=1" \
      --format 'table {{.Names}}	{{.Image}}	{{.Status}}	{{.Labels}}'
    return 0
    ;;
  stop)
    local existing
    existing="$(_find_for_dir)" || die "no run container found for: $dir"
    docker stop "$existing" >/dev/null
    printf "%b[run]%b Stopped %s
" "$GREEN" "$NC" "$existing"
    return 0
    ;;
  logs)
    local existing
    existing="$(_find_for_dir)" || die "no run container found for: $dir"
    exec docker logs -f "$existing"
    ;;
  open)
    local existing line addr hp url
    existing="$(_find_for_dir)" || die "no run container found for: $dir"

    # Normalize path
    [[ -n "$open_path" ]] || open_path="/"
    [[ "$open_path" == /* ]] || open_path="/$open_path"

    if [[ -n "$open_port" ]]; then
      line="$(docker port "$existing" "$open_port" 2>/dev/null | head -n 1 || true)"
      # Some docker versions require proto, try tcp as fallback
      [[ -n "$line" ]] || line="$(docker port "$existing" "${open_port}/tcp" 2>/dev/null | head -n 1 || true)"
    else
      line="$(docker port "$existing" 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -z "$line" ]]; then
      printf "%b[run]%b No published ports found.
" "$YELLOW" "$NC"
      printf "%b[run]%b Tip: start with %blds run --publish 8025:8025%b then %blds run open%b
" \
        "$YELLOW" "$NC" "$BLUE" "$NC" "$BLUE" "$NC"
      return 1
    fi

    # Example line: "8025/tcp -> 0.0.0.0:8025"
    addr="${line##*-> }"
    hp="${addr##*:}"

    url="${open_proto}://localhost:${hp}${open_path}"
    open_url "$url"
    printf "%b[run]%b Opened: %s
" "$GREEN" "$NC" "$url"
    return 0
    ;;
  rm)
    local existing img
    existing="$(_find_for_dir)" || true
    if [[ -n "${existing:-}" ]]; then
      img="$(docker inspect -f '{{.Config.Image}}' "$existing" 2>/dev/null || true)"
      docker rm -f "$existing" >/dev/null
      printf "%b[run]%b Removed container %s
" "$GREEN" "$NC" "$existing"
      if [[ -n "${img:-}" ]]; then
        docker rmi -f "$img" >/dev/null 2>&1 || true
        printf "%b[run]%b Removed image %s
" "$GREEN" "$NC" "$img"
      fi
    else
      printf "%b[run]%b No container found for %s
" "$YELLOW" "$NC" "$dir"
    fi
    return 0
    ;;
  shell | *)
    if ((nobuild == 0)); then
      run_build "$tag" "$dir"
    else
      printf "%b[run]%b Skipping build (--no-build)
" "$YELLOW" "$NC"
    fi

    if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
      printf "%b[run]%b Container already running: %s
" "$GREEN" "$NC" "$name"
    else
      # if a previous container with same name exists but stopped, remove it
      if docker inspect "$name" >/dev/null 2>&1; then
        docker rm -f "$name" >/dev/null 2>&1 || true
      fi
      run_start "$name" "$tag" "$dir" "$keepalive" "$sock" "${publish[@]}"
    fi

    run_exec_shell "$name"
    ;;
  esac
}

cmd_help() {
  cat <<EOF
${CYAN}Usage:${NC}
  lds [--verbose|-v] <command> [args...]
  lds <shortcut> [args...]                # php/composer/node/npm/npx, my/mysql, maria, pg/psql, redis-cli

${CYAN}Global:${NC}
  -v, --verbose     Show docker pull/build progress + extra logs
  -q, --quiet       Quiet mode (default)

${CYAN}Core stack:${NC}
  up                         Start stack (quiet pull by default)
  start                      Alias of up
  stop                       Stop stack (docker compose down)
  down                       Alias of stop
  reload                     Alias of start (recreate) + HTTP reload
  restart                    Stop + up + HTTP reload
  reboot                     Alias of restart
  rebuild [all|<svc...>]     Pull/build selected services without full down (fast iteration)
  config                     Print resolved compose config (uses extras + env-file)
  http reload                Reload HTTP (Nginx/Apache) inside the LB container
  tools                      Shell into SERVER_TOOLS container
  lzd | lazydocker            Open LazyDocker inside SERVER_TOOLS
  core [domain]              Open shell in the container for a domain (or core service)

${CYAN}Domains / hosts:${NC}
  setup domain               Run mkhost wizard, update COMPOSE_PROFILES, up + HTTP reload
  delhost <domain>           Remove a domain host entry + HTTP reload

${CYAN}Setup:${NC}
  setup init                 Create required files (.env, docker/.env, php.ini, etc.)
  setup permissions          Fix permissions for data/logs/config/bin (Linux/macOS; no-op on Windows)
  setup profile|profiles     Configure service profiles (selection menu; writes defaults into docker/.env)

${CYAN}Certificates:${NC}
  certificate install         Install local rootCA (Linux trust store / Windows CurrentUser\\Root)
  certificate uninstall [--all]
                              Remove local rootCA (use --all to remove from known anchor paths)

${CYAN}Doctor:${NC}
  doctor                     Host diagnostics (docker/compose, config validity, ports 80/443, disk, WSL on Windows)

${CYAN}VPN:${NC}
  vpn-fix                    Allow Docker bridge networks to use the active VPN routes (IPv4 + best-effort IPv6)

${CYAN}Notify:${NC}
  notify watch [container]    Stream notifications from SERVER_TOOLS (desktop popups)
  notify test "Title" "Body"  Send a test notification to SERVER_TOOLS

${CYAN}Run (ad-hoc Dockerfile runner):${NC}
  run                         Build+start+exec container for current directory (Dockerfile required)
  run ps|logs|stop|rm          Manage the ad-hoc container for current directory
  run open [port]             Open published port URL (best-effort)
  run --publish|-p A:B         Publish ports (repeatable)
  run --keepalive              Keep container running (exec later)
  run --sock                   Mount /var/run/docker.sock into container (DinD style)

${CYAN}Shortcuts:${NC}
  php|composer <args...>
  my|mysql|mysqldump <args...>
  maria|mariadb|mariadb-dump <args...>
  pg|psql|pg_dump|pg_restore <args...>
  redis|redis-cli <args...>

${CYAN}Examples:${NC}
  lds setup init
  lds setup profiles
  lds up
  lds http reload
  lds certificate install
  lds vpn-fix
  lds run --publish 8025:8025
EOF
}

###############################################################################
# 7. MAIN
###############################################################################
main() {
  need docker
  ((EUID == 0)) || ensure_files_exist "/docker/.env" "/configuration/php/php.ini" "/.env"

  [[ $# -gt 0 ]] || {
    cmd_help
    exit 1
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -v | --verbose)
      VERBOSE=1
      shift
      ;;
    -q | --quiet)
      VERBOSE=0
      shift
      ;;
    --)
      shift
      break
      ;;
    -*) die "Unknown global option: $1" ;;
    *) break ;;
    esac
  done

  [[ $# -gt 0 ]] || {
    cmd_help
    exit 1
  }

  case "${1,,}" in
  php | composer | node | npm | npx) exec "$DIR/bin/$1" "${@:2}" ;;
  pg | pg_restore | pg-restore | pgrestore | pg_dump | pgdump | pg-dump | psql) exec "$DIR/bin/pg" "${@:2}" ;;
  maria | mariadb | mariadbdump | mariadb-dump | mariadb_dump) exec "$DIR/bin/maria" "${@:2}" ;;
  my | mysql | mysqldump | mysql-dump | mysql_dump) exec "$DIR/bin/my" "${@:2}" ;;
  redis | redis-cli) exec "$DIR/bin/redis-cli" "${@:2}" ;;
  *) cmd_"${1,,}" "${@:2}" ;;
  esac
}

main "$@"
