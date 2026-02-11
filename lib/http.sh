# lds lib: http
# shellcheck shell=bash
# Requires lib/docker.sh

http_reload() {
  printf "%bReloading HTTP...%b" "$MAGENTA" "$NC"
  docker ps -qf name=NGINX &>/dev/null && docker exec NGINX nginx -s reload &>/dev/null || true
  docker ps -qf name=APACHE &>/dev/null && docker exec APACHE apachectl graceful &>/dev/null || true
  printf "\r%bHTTP reloaded!   %b\n" "$GREEN" "$NC"
}

