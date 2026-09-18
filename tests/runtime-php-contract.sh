#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

file="$ROOT/docker/dockerfiles/php.Dockerfile"
assert_file "$file"
assert_file_contains "$file" 'ARG PHP_VERSION=8.4'
assert_file_contains "$file" 'FROM php:${PHP_VERSION}-fpm-alpine'
assert_file_contains "$file" 'ARG PHP_PROFILE_KEY=84'
assert_file_contains "$file" 'ARG LINUX_PKG'
assert_file_contains "$file" 'ARG LINUX_PKG_VERSIONED'
assert_file_contains "$file" 'ARG PHP_EXT'
assert_file_contains "$file" 'ARG PHP_EXT_VERSIONED'
assert_file_contains "$file" 'ARG UID=1000'
assert_file_contains "$file" 'ARG GID=1000'
assert_file_contains "$file" 'php-cli-setup.sh'
assert_file_contains "$file" 'ENTRYPOINT ["/usr/local/bin/php-entry"]'
assert_file_contains "$file" 'CMD ["php-fpm"]'
pass "PHP runtime customization contract"
