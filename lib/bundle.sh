# lds lib: bundle
# shellcheck shell=bash
# Requires lib/docker.sh

bundle_collect() {
  local out="${1:-lds-bundle.zip}"
  local tmp; tmp="$(mktemp -d)"
  docker_compose config >"$tmp/compose.config.yaml" 2>/dev/null || true
  docker ps --format '{{json .}}' >"$tmp/docker.ps.jsonl" 2>/dev/null || true
  (docker_compose logs --no-color --tail=1000 2>/dev/null || true) >"$tmp/compose.logs.txt"
  (cd "$tmp" && zip -qr "../$out" .)
  rm -rf "$tmp"
  printf "%s\n" "$out"
}
