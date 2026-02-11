#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Validation helpers

lds_validate_compose() { docker_compose config >/dev/null; }

lds_validate_env() {
  local f="$1"
  [[ -r "$f" ]] || { echo "Missing env: $f" >&2; return 1; }
  return 0
}

lds_validate_profiles() {
  # Quick sanity: ensure COMPOSE_PROFILES doesn't contain empty entries
  [[ "${COMPOSE_PROFILES:-}" =~ ,, ]] && { echo "Invalid COMPOSE_PROFILES: contains empty entry" >&2; return 1; } || true
  return 0
}

