# lds lib: notify
# shellcheck shell=bash
# Requires lib/docker_exec.sh

notify_send() {
  local title="${1:-LDS}" msg="${2:-}"
  tools_exec sh -lc "command -v notify >/dev/null 2>&1 && notify '$title' '$msg' || true"
}
