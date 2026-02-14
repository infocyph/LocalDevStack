#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Docker/Compose wrappers. No side effects.
# Requires: DIR, CFG, COMPOSE_FILE, EXTRAS_DIR; may use ENV_DOCKER.

# ── Sentinels (must be defined under `set -u`) ────────────────────────────────
__EXTRAS_LOADED=${__EXTRAS_LOADED:-0}
__COMPOSE_SVCS_LOADED=${__COMPOSE_SVCS_LOADED:-0}
__COMPOSE_CFG_JSON=${__COMPOSE_CFG_JSON:-}
__COMPOSE_CFG_YAML=${__COMPOSE_CFG_YAML:-}

load_extras() {
  (( ${__EXTRAS_LOADED:-0} )) && return 0
  __EXTRAS_LOADED=1

  [[ -d "$EXTRAS_DIR" ]] || return 0

  # Stable ordering: later -f overrides earlier.
  mapfile -t __EXTRA_FILES < <(
    find "$EXTRAS_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
  )
}

docker_compose() {
  load_extras

  local -a files=()
  if ((${#__EXTRA_FILES[@]})); then
    local f
    for f in "${__EXTRA_FILES[@]}"; do
      files+=(-f "$f")
    done
  fi

  # Prefer Docker Compose v2 ("docker compose"), fallback to v1 ("docker-compose")
  local -a dc=(docker compose)
  if ! docker compose version >/dev/null 2>&1; then
    dc=(docker-compose)
  fi

  "${dc[@]}" \
    --project-directory "$DIR" \
    -f "$COMPOSE_FILE" \
    "${files[@]}" \
    --env-file "$ENV_DOCKER" \
    "$@"
}

# ── docker compose wrappers (QUIET by default) ────────────────────────────────

dc_up() {
  if ((VERBOSE)); then
    docker_compose up "$@"
  else
    docker_compose up --quiet-pull "$@"
  fi
}

dc_pull() {
  if ((VERBOSE)); then
    docker_compose pull "$@"
  else
    docker_compose pull -q "$@"
  fi
}

dc_build() {
  if ((VERBOSE)); then
    docker_compose build "$@"
  else
    docker_compose build --quiet "$@"
  fi
}

# helper for our own minimal logging (still shows in quiet mode)
compose_cfg_json() {
  if [[ -z "${__COMPOSE_CFG_JSON}" ]]; then
    __COMPOSE_CFG_JSON="$(docker_compose config --format json 2>/dev/null || true)"
  fi
  printf '%s' "${__COMPOSE_CFG_JSON}"
}

compose_cfg_yaml() {
  if [[ -z "${__COMPOSE_CFG_YAML}" ]]; then
    __COMPOSE_CFG_YAML="$(docker_compose config 2>/dev/null || true)"
  fi
  printf '%s' "${__COMPOSE_CFG_YAML}"
}

compose_services_load() {
  (( ${__COMPOSE_SVCS_LOADED:-0} )) && return 0
  mapfile -t __COMPOSE_SVCS < <(docker_compose config --services 2>/dev/null || true)
  __COMPOSE_SVCS_LOADED=1
}

compose_service_exists() {
  local want="${1:-}" s
  [[ -n "$want" ]] || return 1
  compose_services_load
  for s in "${__COMPOSE_SVCS[@]}"; do
    [[ "$s" == "$want" ]] && return 0
  done
  return 1
}

resolve_service() {
  local raw="${1:-}" norm svc
  raw="${raw//[[:space:]]/}"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }

  compose_service_exists "$raw" && {
    printf '%s' "$raw"
    return 0
  }

  norm="$(normalize_service "$raw")"
  compose_service_exists "$norm" && {
    printf '%s' "$norm"
    return 0
  }

  if docker inspect "$raw" >/dev/null 2>&1; then
    svc="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$raw" 2>/dev/null || true)"
    if [[ -n "$svc" ]] && compose_service_exists "$svc"; then
      printf '%s' "$svc"
      return 0
    fi
  fi

  printf '%s' "$norm"
}

compose_has_build() {
  local svc="$1" json
  json="$(compose_cfg_json)"
  if [[ -n "$json" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -e --arg s "$svc" '.services[$s].build != null' >/dev/null <<<"$json"
      return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
      COMPOSE_CFG_JSON="$json" python3 - "$svc" <<'PY'
import json, os, sys
svc = sys.argv[1]
cfg = json.loads(os.environ.get("COMPOSE_CFG_JSON", "") or "{}")
sys.exit(0 if cfg.get("services", {}).get(svc, {}).get("build") is not None else 1)
PY
      return $?
    fi
  fi

  compose_cfg_yaml | awk -v s="$svc" '
    $1=="services:" {in_services=1; next}
    in_services && $0 ~ ("^  " s ":$") {in_svc=1; next}
    in_svc && $0 ~ /^  [A-Za-z0-9_.-]+:$/ {exit 1}
    in_svc && $0 ~ /^    build:/ {exit 0}
    END {exit 1}
  '
}

# Enforce deterministic compose project identity (optional).
lds_compose_project_init() {
  # If COMPOSE_PROJECT_NAME already set, keep it.
  : "${COMPOSE_PROJECT_NAME:=${LDS_PROJECT_NAME:-}}"
  [[ -n "${COMPOSE_PROJECT_NAME:-}" ]] || return 0
  export COMPOSE_PROJECT_NAME
}
