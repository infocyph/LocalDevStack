#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Open URL helpers (host-side)

lds_open_url() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 & disown || true; return 0; fi
  if command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 & disown || true; return 0; fi
  if command -v powershell.exe >/dev/null 2>&1; then powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 || true; return 0; fi
  printf "%s
" "$url"
}

