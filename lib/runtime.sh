# lds lib: runtime
# shellcheck shell=bash
# Requires lib/docker_exec.sh

runtime_versions_path() { printf "%s" "${RUNTIME_VERSIONS_JSON:-/etc/share/runtime-versions.json}"; }

runtime_show() {
  local kind="${1:-all}"
  local p; p="$(runtime_versions_path)"
  tools_exec sh -lc "test -r '$p' && cat '$p' || { echo 'runtime-versions.json not found at $p' >&2; exit 1; }" \
    | { command -v jq >/dev/null 2>&1 && jq -r ".${kind}" 2>/dev/null || cat; }
}
