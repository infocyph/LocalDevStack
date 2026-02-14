#!/usr/bin/env bash
# shellcheck shell=bash

lds_validate_compose() {
  if docker_compose config >/dev/null 2>&1; then
    echo "compose: OK"
    return 0
  fi
  echo "compose: FAIL (docker compose config)" >&2
  return 1
}

lds_validate_env() {
  local f="${1:-}"
  [[ -n "$f" ]] || { echo "env: FAIL (missing path)" >&2; return 2; }
  [[ -r "$f" ]] || { echo "env: FAIL (missing/unreadable: $f)" >&2; return 1; }
  echo "env: OK ($f)"
  return 0
}

lds_validate_profiles() {
  # Quick sanity: ensure COMPOSE_PROFILES doesn't contain empty entries
  if [[ "${COMPOSE_PROFILES:-}" =~ ,, ]]; then
    echo "profiles: FAIL (COMPOSE_PROFILES contains empty entry)" >&2
    return 1
  fi
  echo "profiles: OK"
  return 0
}
