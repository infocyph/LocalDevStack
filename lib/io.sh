#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Output helpers. No side effects.

lds_info() { logq info "$*"; }
lds_warn() { logq warn "$*"; }
lds_ok()   { logq ok   "$*"; }

# Confirm helper (non-interactive safe)
lds_confirm() {
  local prompt="${1:-Are you sure?}" default="${2:-n}"
  ask_yes "$prompt" "$default"
}

# Print key/value lines
lds_kv() { printf "%-18s %s\n" "$1" "${2:-}"; }

