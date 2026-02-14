#!/usr/bin/env bash
# shellcheck shell=bash

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
  local -a CREATE_DIRS=(
    "$DIR/data/cloudbeaver"
    "$DIR/data/mysql"
    "$DIR/data/postgresql"
    "$DIR/data/mongo"
    "$DIR/data/mariadb"
    "$DIR/data/elasticsearch"
    "$DIR/data/redis"
    "$DIR/data/mailpit"
    "$DIR/data/redis-insight"
    "$DIR/data/kibana"
    "$DIR/logs"
  )
  mkdir -p "${CREATE_DIRS[@]}"

  if [[ "$OSTYPE" =~ (msys|cygwin) ]]; then
    add_to_windows_path
    printf "%bWindows PATH configured.%b\n" "$GREEN" "$NC"
    return 0
  fi

  ((EUID == 0)) || die "Please run with sudo."

  # Pick a sane group for shared write: prefer docker, else user's primary group
  local grp
  if getent group docker >/dev/null 2>&1; then
    grp="docker"
  else
    grp="$(id -gn "${SUDO_USER:-$USER}")"
  fi

  local owner
  owner="${SUDO_USER:-$USER}"

  # Repo root: readable; owner controls
  chmod 755 "$DIR"
  chown "$owner:$grp" "$DIR" || true

  # Helper: setgid dirs + group-write files
  _perm_tree() {
    local p="$1"
    [[ -e "$p" ]] || return 0
    chown -R "$owner:$grp" "$p" || true
    find "$p" -type d -exec chmod 2775 {} +
    find "$p" -type f -exec chmod 664 {} +
  }

  _perm_tree "$DIR/configuration"
  _perm_tree "$DIR/docker"
  _perm_tree "$DIR/data"
  _perm_tree "$DIR/logs"

  # Binaries
  chmod 755 "$DIR/bin"
  find "$DIR/bin" -type f -exec chmod +x {} + || true
  chmod +x "$DIR/lds" || true

  # Install a convenient "lds" shim on PATH
  if [[ -w /usr/local/bin ]]; then
    ln -fs "$DIR/lds" /usr/local/bin/lds
  else
    # Target user (sudo installs for the invoking user)
    local target_user target_home
    target_user="${SUDO_USER:-$USER}"
    target_home="$(eval echo "~$target_user")"

    local -a candidates=(
      "$target_home/.local/bin"
      "$target_home/bin"
    )

    local ubin=""
    local p
    for p in "${candidates[@]}"; do
      mkdir -p "$p" 2>/dev/null || true
      if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$target_user:$(id -gn "$target_user")" "$p" 2>/dev/null || true
      fi
      if [[ -d "$p" && -w "$p" ]]; then
        ubin="$p"
        break
      fi
    done

    if [[ -n "$ubin" ]]; then
      ln -fs "$DIR/lds" "$ubin/lds"
      case ":$PATH:" in
      *":$ubin:"*) : ;;
      *) printf "%bNote:%b add %s to PATH (e.g. export PATH=\"%s:\$PATH\").\n" "$YELLOW" "$NC" "$ubin" "$ubin" ;;
      esac
    else
      printf "%bWarning:%b couldn't find a writable user bin dir; run:\n  sudo ln -sf %s /usr/local/bin/lds\n" \
        "$YELLOW" "$NC" "$DIR/lds"
    fi
  fi

  printf "%bPermissions assigned (%s:%s).%b\n" "$GREEN" "$owner" "$grp" "$NC"
}
