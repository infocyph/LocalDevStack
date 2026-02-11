#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# .env helpers (read/update). No side effects.

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

# Unique identity (avoid conflicts with other mkcert/dev CAs)
CA_BASENAME="localdevstack-rootca"
CA_NICK="LocalDevStack Root CA"


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


# Safe .env load (optional) - whitelist pattern.
lds_env_load() {
  local f="${1:-}"
  [[ -r "$f" ]] || return 0
  set -o allexport
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" || true)
  set +o allexport
}

