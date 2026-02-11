# lds lib: cert
# shellcheck shell=bash
# Requires lib/docker_exec.sh

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

install_ca_nss_user() {
  local ca_file="$1"
  command -v certutil >/dev/null 2>&1 || return 0

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

uninstall_ca_nss_user() {
  command -v certutil >/dev/null 2>&1 || return 0
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
    if command -v update-ca-certificates >/dev/null 2>&1; then
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
    if command -v trust >/dev/null 2>&1; then
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
    if command -v update-ca-trust >/dev/null 2>&1; then
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
    if command -v trust >/dev/null 2>&1; then
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
    if command -v update-ca-certificates >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (update-ca-certificates)…\n" "$CYAN" "$NC"
      update-ca-certificates || printf "%bWARN%b: update-ca-certificates failed.\n" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: update-ca-certificates not found; trust store not refreshed.\n" "$YELLOW" "$NC" >&2
    fi

    if command -v trust >/dev/null 2>&1; then
      printf "%bSyncing p11-kit%b (trust extract-compat)…\n" "$CYAN" "$NC"
      trust extract-compat >/dev/null 2>&1 || printf "%bWARN%b: trust extract-compat failed. Skipping.\n" "$YELLOW" "$NC" >&2
    fi
    ;;
  rhel)
    if command -v update-ca-trust >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (update-ca-trust extract)…\n" "$CYAN" "$NC"
      update-ca-trust extract || printf "%bWARN%b: update-ca-trust extract failed.\n" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: update-ca-trust not found; trust store not refreshed.\n" "$YELLOW" "$NC" >&2
    fi
    ;;
  arch)
    if command -v trust >/dev/null 2>&1; then
      printf "%bUpdating trust store%b (trust extract-compat)…\n" "$CYAN" "$NC"
      trust extract-compat >/dev/null 2>&1 || printf "%bWARN%b: trust extract-compat failed.\n" "$YELLOW" "$NC" >&2
    else
      printf "%bWARN%b: 'trust' not found; trust store not refreshed.\n" "$YELLOW" "$NC" >&2
    fi
    ;;
  *)
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

