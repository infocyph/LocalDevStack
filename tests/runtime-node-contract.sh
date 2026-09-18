#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

file="$ROOT/docker/dockerfiles/node.Dockerfile"
assert_file "$file"
assert_file_contains "$file" 'ARG NODE_VERSION=current'
assert_file_contains "$file" 'FROM node:${NODE_VERSION}-alpine'
[[ "$(grep -c '^ARG NODE_VERSION' "$file")" -eq 2 ]] ||
  fail "NODE_VERSION must be redeclared inside the build stage"
assert_file_contains "$file" 'ARG LINUX_PKG'
assert_file_contains "$file" 'ARG LINUX_PKG_VERSIONED'
assert_file_contains "$file" 'ARG NODE_GLOBAL'
assert_file_contains "$file" 'ARG NODE_GLOBAL_VERSIONED'
assert_file_contains "$file" 'ARG UID=1000'
assert_file_contains "$file" 'ARG GID=1000'
assert_file_contains "$file" 'ARG SCRIPTOMATIC_REF=main'
assert_file_contains "$file" 'ARG SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT=10'
assert_file_contains "$file" 'ARG SCRIPTOMATIC_DOWNLOAD_MAX_TIME=120'
assert_file_contains "$file" 'ARG SCRIPTOMATIC_DOWNLOAD_RETRIES=3'
assert_file_contains "$file" 'Scriptomatic/${SCRIPTOMATIC_REF}/bash/node-cli-setup.sh'
assert_file_contains "$file" '--connect-timeout "${SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT}"'
assert_file_contains "$file" '--max-time "${SCRIPTOMATIC_DOWNLOAD_MAX_TIME}"'
assert_file_contains "$file" '--retry "${SCRIPTOMATIC_DOWNLOAD_RETRIES}"'
assert_file_contains "$file" 'test -s "$bootstrap"'
assert_file_contains "$file" 'bash -n "$bootstrap"'
assert_file_contains "$file" 'resolved_node_version="$(node -v'
assert_file_contains "$file" 'SCRIPTOMATIC_REF="${SCRIPTOMATIC_REF}"'
assert_file_contains "$file" 'bash "$bootstrap" "${USERNAME}" "$resolved_node_version"'
assert_file_contains "$file" 'EXPOSE 3000'
assert_file_contains "$file" 'ENTRYPOINT ["/usr/local/bin/node-entry"]'

if grep -Eq '^ADD https?://|Scriptomatic/master/' "$file"; then
  fail "Node runtime must not use remote ADD or the stale Scriptomatic master ref"
fi

pass "Node selected-version Alpine runtime and Scriptomatic bootstrap contract"
