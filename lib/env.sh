# shellcheck shell=bash
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

