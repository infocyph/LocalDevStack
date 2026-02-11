#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Network helpers

lds_net_list() { docker network ls; }

lds_net_inspect() {
  local n="$1"
  docker network inspect "$n"
}

lds_net_conflicts() {
  # naive conflict check against common VPN ranges
  docker network inspect $(docker network ls -q) 2>/dev/null | rg -n 'Subnet|Gateway' || true
}

