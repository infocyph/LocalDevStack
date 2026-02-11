#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

http_reload() {
  printf "%bReloading HTTP...%b" "$MAGENTA" "$NC"
  docker ps -qf name=NGINX &>/dev/null && docker exec NGINX nginx -s reload &>/dev/null || true
  docker ps -qf name=APACHE &>/dev/null && docker exec APACHE apachectl graceful &>/dev/null || true
  printf "\r%bHTTP reloaded!   %b\n" "$GREEN" "$NC"
}

###############################################################################
# 2. PERMISSIONS FIX-UP
###############################################################################

