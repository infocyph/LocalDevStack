#!/usr/bin/env bash
# shellcheck shell=bash

# docker exec helpers
# Requires: docker in PATH

docker_exec_raw() {
  local c="$1"; shift || true
  docker exec "$c" "$@"
}

# Auto add -i/-t when the current process has a TTY.
docker_exec() {
  local c="$1"; shift || true
  local -a flags=()

  # interactive stdin
  [[ -t 0 ]] && flags+=(-i)
  # tty for stdout
  [[ -t 1 ]] && flags+=(-t)

  docker exec "${flags[@]}" "$c" "$@"
}

docker_exec_sh() {
  local c="$1"; shift || true
  # shell inside container; keep it interactive when possible
  docker_exec "$c" sh -lc "$*"
}

tools_exec_raw() { docker_exec_raw SERVER_TOOLS "$@"; }
tools_exec() { docker_exec SERVER_TOOLS "$@"; }
tools_sh()   { docker exec -it SERVER_TOOLS bash; }

nginx_exec() { docker_exec NGINX "$@"; }
nginx_sh()   { docker exec -it NGINX sh; }

container_running() {
  local name="$1"
  docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx 'true'
}

container_exists() {
  local name="$1"
  docker inspect "$name" >/dev/null 2>&1
}
