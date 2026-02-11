#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# docker exec helpers
# Requires: docker in PATH

docker_exec() {
  local c="$1"; shift || true
  docker exec "$c" "$@"
}

docker_exec_sh() {
  local c="$1"; shift || true
  docker exec -it "$c" sh -lc "$*"
}

tools_exec() { docker_exec SERVER_TOOLS "$@"; }
tools_sh()   { docker_exec -it SERVER_TOOLS bash; }

nginx_exec() { docker_exec NGINX "$@"; }
nginx_sh()   { docker_exec -it NGINX sh; }

container_running() {
  local name="$1"
  docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx 'true'
}

container_exists() {
  local name="$1"
  docker inspect "$name" >/dev/null 2>&1
}

