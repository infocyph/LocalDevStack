#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Diagnostics primitives powered by SERVER_TOOLS utilities.

lds_diag_dns() {
  local host="$1"
  tools_exec sh -lc "dig +short '$host' || true; getent hosts '$host' || true"
}

lds_diag_route() { tools_exec sh -lc "ip r; echo; ip a"; }

lds_diag_tcp() {
  local host="$1" port="$2"
  tools_exec sh -lc "nc -vz -w 3 '$host' '$port'"
}

lds_diag_http_head() {
  local url="$1"
  tools_exec sh -lc "curl -vkI --max-time 10 '$url'"
}

lds_diag_tls() {
  local host="$1" port="${2:-443}"
  tools_exec sh -lc "openssl s_client -connect '$host:$port' -servername '$host' -showcerts </dev/null"
}

