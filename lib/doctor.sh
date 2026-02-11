# lds lib: doctor
# shellcheck shell=bash
# Requires lib/diag.sh and lib/docker.sh

doctor_lint() { tools_exec sh -lc "command -v shellcheck >/dev/null 2>&1 && shellcheck -x '$1' || true"; }
doctor_scan_logs() {
  local svc="${1:-}"
  if [[ -n "$svc" ]]; then
    docker_compose logs --no-color --tail=500 "$svc" 2>/dev/null | tools_exec sh -lc "rg -n 'error|fail|panic|permission denied' || true"
  else
    docker_compose logs --no-color --tail=500 2>/dev/null | tools_exec sh -lc "rg -n 'error|fail|panic|permission denied' || true"
  fi
}
