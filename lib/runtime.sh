#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Runtime information helpers (php/node versions). Implemented via SERVER_TOOLS runtime-versions.json.

lds_runtime_file_guess() {
  # Prefer tools shared path used in your stack
  echo "/etc/share/runtime-versions.json"
}

lds_runtime_show() {
  local which="${1:-all}"
  local f; f="$(lds_runtime_file_guess)"
  tools_exec sh -lc "test -r '$f' && cat '$f' || { echo 'runtime versions file not found: '$f'' >&2; exit 1; }" || return $?
  return 0
}

