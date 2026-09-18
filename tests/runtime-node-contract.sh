#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

file="$ROOT/docker/dockerfiles/node.Dockerfile"
assert_file "$file"
assert_file_contains "$file" 'ARG NODE_VERSION=current'
assert_file_contains "$file" 'FROM node:${NODE_VERSION}-alpine'
assert_file_contains "$file" 'ARG LINUX_PKG'
assert_file_contains "$file" 'ARG LINUX_PKG_VERSIONED'
assert_file_contains "$file" 'ARG NODE_GLOBAL'
assert_file_contains "$file" 'ARG NODE_GLOBAL_VERSIONED'
assert_file_contains "$file" 'ARG UID=1000'
assert_file_contains "$file" 'ARG GID=1000'
assert_file_contains "$file" 'node-cli-setup.sh'
assert_file_contains "$file" 'EXPOSE 3000'
assert_file_contains "$file" 'ENTRYPOINT ["/usr/local/bin/node-entry"]'
pass "Node runtime customization contract"
