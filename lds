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
read_default() {
  local prompt=$1 default=$2 input
  read -rp "$(printf '%b%s [default: %s]:%b ' "$CYAN" "$prompt" "$default" "$NC")" input
  printf '%s' "${input:-$default}"
}

ask_yes() {
  local prompt="$1" ans
  read -rp "$(printf "%b%s (y/n): %b" "$BLUE" "$prompt" "$NC")" ans
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
fix_perms() {
  [[ "$OSTYPE" =~ (msys|cygwin) ]] && return
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
# Profiles (merged from docker/utilities/profiles)
# ─────────────────────────────────────────────────────────────────────────────

declare -A SERVICES=(
  [ELASTICSEARCH]="elasticsearch"
  [MYSQL]="mysql"
  [MARIADB]="mariadb"
  [MONGODB]="mongodb"
  [REDIS]="redis"
  [POSTGRESQL]="postgresql"
)

declare -a SERVICE_ORDER=(ELASTICSEARCH MYSQL MARIADB MONGODB REDIS POSTGRESQL)

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

process_service() {
  local service="$1"
  printf "\n%b→ %s%b\n" "$YELLOW" "$service" "$NC"
  ask_yes "Enable $service?" || {
    printf "%bSkipping %s%b\n" "$RED" "$service" "$NC"
    return
  }

  local profile="${SERVICES[$service]}"
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
  local svc
  for svc in "${SERVICE_ORDER[@]}"; do
    process_service "$svc"
  done
  flush_envs
  flush_profiles
  printf "\n%b✅ All services configured!%b\n" "$GREEN" "$NC"
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
  local os_id="unknown" os_like="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-unknown}"
    os_like="${ID_LIKE:-unknown}"
  fi
  printf '%s|%s
' "$os_id" "$os_like"
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

install_ca() {
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
  #   lds core           -> auto-detect project by current directory and open correct container

  local domain="${1:-}"
  if [[ -n "$domain" ]]; then
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
  fi

  core_auto
}

# ------------------------------------------------------------
# core auto-detect (host PWD -> /app in php container)
# ------------------------------------------------------------
core_auto() {
  local pwd="${PWD}"

  local working_dir
  if [[ -n "${WORKING_DIR:-}" ]]; then
    working_dir="${WORKING_DIR}"
  elif [[ -d /opt/project/LocalDevStack ]]; then
    working_dir="/opt/project/LocalDevStack"
  else
    working_dir="${DIR}"
  fi

  # Compose default: "${PROJECT_DIR:-./../../../application}:/app"
  local host_app_root
  if [[ -n "${PROJECT_DIR:-}" ]]; then
    host_app_root="${PROJECT_DIR}"
  else
    host_app_root="${working_dir%/}/../application"
  fi

  local -a confs=()
  local d f
  for d in "${working_dir%/}/configuration/nginx" "${working_dir%/}/configuration/apache" "${working_dir%/}/configuration/httpd" "${working_dir%/}/configuration/apache/sites-enabled" "${working_dir%/}/configuration/httpd/sites-enabled"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d "" f; do
      confs+=("$f")
    done < <(find "$d" -maxdepth 1 -type f -name "*.conf" -print0 2>/dev/null || true)
  done

  local best_container="" best_host_root="" best_len=0

  local php c_src app_path app_root rel host_proj l
  for f in "${confs[@]:-}"; do
    php="$(conf_php_container "$f")"
    if [[ -n "$php" ]]; then
      # Real host source for /app from the php container (beats env guesses)
      c_src="$(docker_mount_source "$php" "/app")"
      [[ -n "$c_src" ]] || c_src="$host_app_root"

      while IFS= read -r app_path; do
        [[ -n "$app_path" ]] || continue
        app_root="$(normalize_app_root "$app_path")"

        rel="${app_root#/app/}"
        host_proj="${c_src%/}/${rel}"

        # Candidate is meaningful only if PWD is inside it
        [[ "$pwd" == "$host_proj"* ]] || continue

        l="${#host_proj}"
        if ((l > best_len)); then
          best_len=$l
          best_container="$php"
          best_host_root="$host_proj"
        fi
      done < <(conf_app_paths "$f")

      # fallback: if no /app paths were detected in conf
      if [[ -z "$best_container" ]]; then
        [[ "$pwd" == "$c_src"* ]] || continue
        l="${#c_src}"
        if ((l > best_len)); then
          best_len=$l
          best_container="$php"
          best_host_root="$c_src"
        fi
      fi

      continue
    fi

    local node ctr_src
    node="$(conf_node_container "$f")"
    [[ -n "$node" ]] || continue

    ctr_src="$(docker_mount_source "$node" "/app")"
    [[ -n "$ctr_src" ]] || ctr_src="$host_app_root"

    [[ "$pwd" == "$ctr_src"* ]] || continue

    l="${#ctr_src}"
    if ((l > best_len)); then
      best_len=$l
      best_container="$node"
      best_host_root="$ctr_src"
    fi
  done

  # Fallback: if PWD is under /app mount of a running PHP_* container, use it
  if [[ -z "$best_container" ]]; then
    local cand cand_src
    cand="$(docker ps --format "{{.Names}}" | grep -m1 "^PHP_" || true)"
    if [[ -n "$cand" ]]; then
      cand_src="$(docker_mount_source "$cand" "/app")"
      if [[ -n "$cand_src" && "$pwd" == "${cand_src%/}/"* ]]; then
        best_container="$cand"
        best_host_root="$cand_src"
      fi
    fi
  fi

  [[ -n "$best_container" ]] || die "No matching domain for current directory: $pwd (try: lds core <domain>)"

  # Map host PWD -> /app path inside container
  local rel_path container_path
  rel_path="${pwd#${best_host_root%/}/}"
  container_path="/app/${rel_path}"

  printf "%b[core]%b %s -> %s:%s
" "$CYAN" "$NC" "$pwd" "$best_container" "$container_path"

  docker exec -it "$best_container" sh -lc "cd \"$container_path\" 2>/dev/null || exit 1; if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"
}

conf_php_container() {
  local f="$1"

  # 1) Apache: SetHandler "proxy:fcgi://PHP_8.4:9000"
  local c=""
  c="$(grep -Eo 'proxy:fcgi://[^:/"]+' "$f" 2>/dev/null | head -n1 | sed 's#proxy:fcgi://##')"
  [[ -n "$c" ]] && {
    printf "%s" "$c"
    return 0
  }

  # 2) Nginx: fastcgi_pass PHP_8.4:9000;
  c="$(grep -Eo 'fastcgi_pass[[:space:]]+[^;:]+:9000' "$f" 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/:9000$//')"
  [[ -n "$c" ]] && {
    printf "%s" "$c"
    return 0
  }

  # 3) Nginx: proxy_cookie_domain PHP_8.4 local.example;
  c="$(grep -Eo 'proxy_cookie_domain[[:space:]]+[^[:space:];]+' "$f" 2>/dev/null | head -n1 | awk '{print $2}')"
  [[ -n "$c" ]] && {
    printf "%s" "$c"
    return 0
  }

  return 0
}

conf_app_paths() {
  local f="$1"
  [[ -r "$f" ]] || return 0

  LC_ALL=C awk '
    {
      s=$0
      while (match(s, /\/app\/[^;[:space:]"'\''<>]+/)) {
        print substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$f" | LC_ALL=C sort -u || true
}

normalize_app_root() {
  local p="$1"
  p="${p%/}"
  p="${p%/public}"
  p="${p%/public_html}"
  p="${p%/dist}"
  printf "%s" "$p"
}

docker_mount_source() {
  local container="$1" dest="$2"
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "'"$dest"'"}}{{.Source}}{{end}}{{end}}' "$container" 2>/dev/null || true
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
  # Quick environment diagnostics + install hints (best-effort).
  local os_id os_like family
  IFS='|' read -r os_id os_like < <(detect_os_family)

  printf "%bDoctor%b — environment checks\n" "$MAGENTA" "$NC"
  printf "%bOS%b: id=%s like=%s\n" "$CYAN" "$NC" "$os_id" "$os_like"

  _ok() { printf "  %b✔%b %s\n" "$GREEN" "$NC" "$*"; }
  _warn() { printf "  %b!%b %s\n" "$YELLOW" "$NC" "$*"; }
  _bad() { printf "  %b✘%b %s\n" "$RED" "$NC" "$*"; }

  _has() { command -v "$1" >/dev/null 2>&1; }

  # Docker CLI + daemon
  if _has docker; then
    _ok "docker: $(docker --version 2>/dev/null || echo 'present')"
    if docker info >/dev/null 2>&1; then
      _ok "docker daemon: reachable"
    else
      _bad "docker daemon: not reachable (is Docker running? permissions?)"
    fi
  else
    _bad "docker: missing"
  fi

  # Compose
  if docker compose version >/dev/null 2>&1; then
    _ok "compose: docker compose"
  elif _has docker-compose; then
    _ok "compose: docker-compose"
  else
    _bad "compose: missing (need docker compose plugin or docker-compose)"
  fi

  # Common tools used by this script
  for c in awk sed grep find sort; do
    _has "$c" && _ok "$c: present" || _bad "$c: missing"
  done

  # Optional-but-valuable tools
  _has mkcert && _ok "mkcert: present" || _warn "mkcert: not found (needed for local TLS automation)"
  _has openssl && _ok "openssl: present" || _warn "openssl: not found (useful for debugging certs)"
  (_has wget || _has curl) && _ok "http client: present" || _warn "http client: missing (wget/curl recommended)"

  # layout checks
  [[ -f "$COMPOSE_FILE" ]] && _ok "compose file: $COMPOSE_FILE" || _bad "compose file missing: $COMPOSE_FILE"
  [[ -f "$ENV_DOCKER" ]] && _ok "env file: $ENV_DOCKER" || _warn "env file missing: $ENV_DOCKER (run: lds setup init)"

  # CA tooling by distro family
  if _has update-ca-certificates; then
    _ok "update-ca-certificates: present"
  else
    _warn "update-ca-certificates: not found (Debian/Ubuntu/Alpine CA updates)"
  fi

  if _has update-ca-trust; then
    _ok "update-ca-trust: present"
  else
    _warn "update-ca-trust: not found (RHEL/Fedora CA updates)"
  fi

  if _has trust; then
    _ok "trust (p11-kit): present"
  else
    _warn "trust (p11-kit): not found (Arch / p11-kit trust store)"
  fi

  printf "\n%bInstall hints%b (best guess)\n" "$CYAN" "$NC"

  # Package manager heuristics (print commands, do NOT execute)
  if _has apt-get; then
    _warn "Debian/Ubuntu:"
    printf "    sudo apt-get update && sudo apt-get install -y ca-certificates curl wget openssl p11-kit\n"
    printf "    # Docker: https://docs.docker.com/engine/install/\n"
    printf "    sudo apt-get install -y docker-compose-plugin\n"
  elif _has dnf; then
    _warn "Fedora/RHEL (dnf):"
    printf "    sudo dnf install -y ca-certificates curl wget openssl p11-kit-trust\n"
    printf "    # Docker: https://docs.docker.com/engine/install/\n"
  elif _has yum; then
    _warn "RHEL/CentOS (yum):"
    printf "    sudo yum install -y ca-certificates curl wget openssl p11-kit-trust\n"
    printf "    # Docker: https://docs.docker.com/engine/install/\n"
  elif _has pacman; then
    _warn "Arch:"
    printf "    sudo pacman -Syu --noconfirm ca-certificates curl wget openssl p11-kit\n"
    printf "    # Docker + compose plugin per Arch wiki\n"
  elif _has apk; then
    _warn "Alpine:"
    printf "    sudo apk add --no-cache ca-certificates curl wget openssl p11-kit\n"
    printf "    sudo update-ca-certificates\n"
  elif _has zypper; then
    _warn "SUSE:"
    printf "    sudo zypper install -y ca-certificates curl wget openssl p11-kit\n"
  else
    _warn "No known package manager detected. Install: docker + compose + ca-certificates + openssl + p11-kit."
  fi

  printf "\n%bTips%b\n" "$CYAN" "$NC"
  printf "  - Use: %blds certificate uninstall --all%b if you switched distros/paths.\n" "$BLUE" "$NC"
  printf "  - Use: %blds run --publish 8025:8025%b to expose ports for 'lds run open'.\n" "$BLUE" "$NC"
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
${CYAN}Usage:${NC} lds [--verbose|-v] <command> [options]

${CYAN}Default:${NC} quiet docker compose operations. Add ${CYAN}-v${NC} / ${CYAN}--verbose${NC} to see pull/build progress.

${CYAN}Core commands:${NC}
  up / start                 Start docker stack (quiet pull by default)
  stop / down                Stop stack
  reload / restart           Restart stack + reload HTTP
  rebuild all|<svc...>       Rebuild/pull services (no full down)
  config                     Validate compose
  tools                      Enter SERVER_TOOLS container
  lzd | lazydocker           Start LazyDocker
  http reload                Reload Nginx/Apache
  core <domain>              Open bash in PHP container for <domain>

${CYAN}Setup commands:${NC}
  setup init                 Initialize Primaries!
  setup permissions          Assign/Fix directory/file permissions
  setup domain               Setup domain
  setup profiles             Setup database profiles

${CYAN}Misc:${NC}
  doctor                     Diagnose environment + show install hints
  certificate install         Install local rootCA
  certificate uninstall [--all] Remove local rootCA (use --all to remove from all known anchor paths)
  run [stop|rm|ps|logs|open] [opts]  Build/run/exec ad-hoc Dockerfile in current dir
  notify watch [container]   Watch SERVER_TOOLS notifications and show desktop popups
  notify test "T" "B"        Send a test notification into SERVER_TOOLS
  help                       This help
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
