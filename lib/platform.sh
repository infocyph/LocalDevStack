# shellcheck shell=bash
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

