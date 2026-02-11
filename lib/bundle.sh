#!/usr/bin/env bash

# Support bundle creation.
lds_bundle_create() {
  local out="${1:-lds-bundle.zip}"
  local tmp; tmp="$(mktemp -d)"
  {
    echo "Collecting compose config..."
    docker_compose config >"$tmp/compose.config.yaml" 2>"$tmp/compose.config.err" || true
    docker ps -a >"$tmp/docker.ps.txt" 2>&1 || true
    docker network ls >"$tmp/docker.networks.txt" 2>&1 || true
    docker_compose ps >"$tmp/compose.ps.txt" 2>&1 || true
    if command -v rg >/dev/null 2>&1; then :; fi
  } >/dev/null 2>&1 || true

  (cd "$tmp" && zip -qr "../$out" .) || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  printf "%s
" "$out"
}
