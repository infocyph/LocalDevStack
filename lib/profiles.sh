#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Profile management helpers. No side effects until called.

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
  [elasticsearch]="ELASTICSEARCH_VERSION=9.2.4"
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
# 4a. LAUNCH PHP CONTAINER INSIDE DOCROOT
###############################################################################

