# shellcheck shell=bash

# Detect a FastFlow-supported AMD XDNA2 NPU.
# FastFlowLM currently identifies XDNA2 as AMD PCI vendor/device 1022:17f0.
# The paths are injectable so the contract can be exercised without NPU hardware.
fastflow_npu_supported() {
  local accel="${LDS_AI_ACCEL_DEVICE:-/dev/accel/accel0}"
  local sysfs="${LDS_AI_ACCEL_SYSFS:-/sys/class/accel/accel0/device}"
  local vendor="" device="" driver=""

  [[ -e "$accel" ]] || return 1
  [[ -r "$sysfs/vendor" && -r "$sysfs/device" ]] || return 1

  vendor="$(tr '[:upper:]' '[:lower:]' <"$sysfs/vendor" | tr -d '[:space:]')"
  device="$(tr '[:upper:]' '[:lower:]' <"$sysfs/device" | tr -d '[:space:]')"
  if [[ -L "$sysfs/driver" ]]; then
    driver="$(basename "$(readlink -f "$sysfs/driver" 2>/dev/null || true)")"
  fi

  [[ "$vendor" == "0x1022" && "$device" == "0x17f0" ]] || return 1
  [[ -z "$driver" || "$driver" == "amdxdna" ]] || return 1
}

# Detect the preferred local-AI runtime from host accelerator capability.
# A supported XDNA2 NPU wins because FastFlowLM can use it directly. NVIDIA is
# next, then ROCm-capable AMD GPU, with CPU as the portable fallback.
detect_ai_runtime() {
  if fastflow_npu_supported; then
    printf '%s' npu
    return 0
  fi

  if has_cmd nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
    printf '%s' nvidia
    return 0
  fi
  if has_cmd nvidia-smi.exe && nvidia-smi.exe -L >/dev/null 2>&1; then
    printf '%s' nvidia
    return 0
  fi

  # The AMD Compose override requires the Linux ROCm device nodes, so merely
  # having an AMD CPU/GPU name is not sufficient.
  if [[ -e /dev/kfd && -d /dev/dri ]]; then
    printf '%s' amd
    return 0
  fi

  printf '%s' cpu
}

ai_provider_for_runtime() {
  case "${1,,}" in
  npu) printf '%s' fastflow ;;
  "" | cpu | nvidia | amd) printf '%s' ollama ;;
  *) return 1 ;;
  esac
}

ai_service_for_runtime() {
  case "$(ai_provider_for_runtime "${1:-}")" in
  fastflow) printf '%s' llm-fastflow ;;
  ollama) printf '%s' llm-ollama ;;
  *) return 1 ;;
  esac
}

ai_model_default_for_runtime() {
  case "${1,,}" in
  npu) printf '%s' 'qwen3.5:9b' ;;
  "" | cpu | nvidia | amd) printf '%s' 'qwen3:14b' ;;
  *) return 1 ;;
  esac
}

effective_ai_runtime() {
  local runtime
  runtime="$(compose_control_value LDS_AI_RUNTIME "")"
  [[ -n "$runtime" ]] || runtime="$(detect_ai_runtime)"
  printf '%s' "${runtime,,}"
}

effective_ai_model() {
  local runtime="${1:-}" configured
  [[ -n "$runtime" ]] || runtime="$(effective_ai_runtime)"
  configured="$(compose_control_value LDS_AI_MODEL "")"
  if [[ -n "$configured" ]]; then
    printf '%s' "$configured"
  else
    ai_model_default_for_runtime "$runtime"
  fi
}

host_cpu_is_amd() {
  if [[ -r /proc/cpuinfo ]] &&
    grep -qiE '^[[:space:]]*vendor_id[[:space:]]*:[[:space:]]*AuthenticAMD([[:space:]]|$)' /proc/cpuinfo; then
    return 0
  fi

  if has_cmd lscpu &&
    lscpu 2>/dev/null | grep -qiE '^Vendor ID:[[:space:]]*AuthenticAMD([[:space:]]|$)'; then
    return 0
  fi

  return 1
}

ai_igpu_default_for_runtime() {
  if [[ "${1,,}" == "amd" ]] && host_cpu_is_amd; then
    printf '%s' 1
  else
    printf '%s' 0
  fi
}

llm_arch_for_runtime() {
  case "${1,,}" in
  amd) printf '%s' amd-latest ;;
  "" | cpu | nvidia | npu) printf '%s' latest ;;
  *) return 1 ;;
  esac
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

  local owner group
  owner="${SUDO_USER:-${USER:-}}"
  [[ -n "$owner" ]] || owner="$(id -un)"
  id "$owner" >/dev/null 2>&1 || die "Cannot resolve permission owner: $owner"

  if getent group docker >/dev/null 2>&1; then
    group=docker
  else
    group="$(id -gn "$owner")"
  fi

  chmod 755 "$DIR"

  chown -R "$owner:$group" "$DIR/configuration" "$DIR/logs"
  find "$DIR/configuration" -type d -exec chmod 2775 {} +
  find "$DIR/configuration" -type f -exec chmod 0664 {} +
  find "$DIR/logs" -type d -exec chmod 2775 {} +
  find "$DIR/logs" -type f -exec chmod 0664 {} +

  # Secret-bearing host directories stay private to the workstation owner.
  for private_dir in "$DIR/configuration/ssh" "$DIR/configuration/sops/keys"; do
    [[ -d "$private_dir" ]] || continue
    chown -R "$owner:$group" "$private_dir"
    find "$private_dir" -type d -exec chmod 0700 {} +
    find "$private_dir" -type f -exec chmod 0600 {} +
  done

  # Public CA exports may stay readable, but password-protected/user key
  # artifacts must retain the restrictive mode Tools assigns to them.
  if [[ -d "$DIR/configuration/ssl" ]]; then
    find "$DIR/configuration/ssl" -type d -exec chmod 0755 {} +
    find "$DIR/configuration/ssl" -type f -exec chmod 0644 {} +
    find "$DIR/configuration/ssl" -type f \(       -name '*.p12' -o -name '*.pfx' -o -name '*.key' -o -name '*-key.pem'     \) -exec chmod 0600 {} +
  fi

  find "$DIR/docker" -type d -exec chmod 0755 {} +
  find "$DIR/docker" -type f -exec chmod 0644 {} +

  chmod 0755 "$DIR/bin"
  find "$DIR/bin" -type f -exec chmod 0755 {} +
  if [[ -d "$DIR/lib" ]]; then
    find "$DIR/lib" -type d -exec chmod 0755 {} +
    find "$DIR/lib" -type f -exec chmod 0644 {} +
  fi
  chmod 0755 "$DIR/lds"

  ln -fs "$DIR/lds" /usr/local/bin/lds
  printf "%bPermissions assigned to %s:%s.%b\n" "$GREEN" "$owner" "$group" "$NC"
}
