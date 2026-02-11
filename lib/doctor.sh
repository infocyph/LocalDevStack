#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Doctor checks - reusable pieces.

lds_doctor_shellcheck() {
  local target="${1:-.}"
  tools_exec shellcheck -x "$target"
}

lds_doctor_scan_logs() {
  local pattern="${1:-error|failed|panic|permission denied}"
  # expects docker to be available in tools container
  tools_exec sh -lc "docker ps --format '{{.Names}}' | while read -r c; do echo '==> '"$c"; docker logs --tail 200 "$c" 2>&1 | rg -n -i "$pattern" || true; done"
}

lds_doctor_compose_config() {
  docker_compose config >/dev/null
}

