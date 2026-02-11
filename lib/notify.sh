#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Notification helpers (delegated)

lds_notify_send() {
  # If you have a notifierd socket bridge in SERVER_TOOLS, use it.
  # Fallback: just echo.
  local msg="${1:-}"
  tools_exec sh -lc "command -v notify >/dev/null 2>&1 && notify '$msg' || echo '$msg'"
}

