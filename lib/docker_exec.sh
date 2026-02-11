# lds lib: docker_exec
# shellcheck shell=bash
# Requires lib/docker.sh

docker_exists() { docker inspect "$1" >/dev/null 2>&1; }
docker_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]; }

docker_exec() {
  local c="$1"; shift || true
  docker exec -i "$c" "$@"
}

docker_exec_tty() {
  local c="$1"; shift || true
  docker exec -it "$c" "$@"
}

tools_container() {
  if docker_running "SERVER_TOOLS" 2>/dev/null; then printf "SERVER_TOOLS"
  elif docker_running "SERVERTOOLS" 2>/dev/null; then printf "SERVERTOOLS"
  elif docker_running "NGINX" 2>/dev/null; then printf "NGINX"
  else printf ""; fi
}

tools_exec() {
  local c; c="$(tools_container)"
  [[ -n "$c" ]] || die "SERVER_TOOLS (or NGINX) container is not running"
  docker_exec "$c" "$@"
}

tools_sh() {
  local c; c="$(tools_container)"
  [[ -n "$c" ]] || die "SERVER_TOOLS (or NGINX) container is not running"
  docker_exec_tty "$c" bash -l
}
