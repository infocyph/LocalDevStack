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
assert_file_contains "$file" 'ARG SCRIPTOMATIC_REF=main'
assert_file_contains "$file" 'ARG SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT=10'
assert_file_contains "$file" 'ARG SCRIPTOMATIC_DOWNLOAD_MAX_TIME=120'
assert_file_contains "$file" 'ARG SCRIPTOMATIC_DOWNLOAD_RETRIES=3'
assert_file_contains "$file" 'Scriptomatic/${SCRIPTOMATIC_REF}/bash/php-cli-setup.sh'
assert_file_contains "$file" '--connect-timeout "${SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT}"'
assert_file_contains "$file" '--max-time "${SCRIPTOMATIC_DOWNLOAD_MAX_TIME}"'
assert_file_contains "$file" '--retry "${SCRIPTOMATIC_DOWNLOAD_RETRIES}"'
assert_file_contains "$file" 'test -s "$bootstrap"'
assert_file_contains "$file" 'bash -n "$bootstrap"'
assert_file_contains "$file" 'SCRIPTOMATIC_REF="${SCRIPTOMATIC_REF}"'
assert_file_contains "$file" 'bash "$bootstrap" "${USERNAME}" "${PHP_VERSION}"'
assert_file_contains "$file" 'ENTRYPOINT ["/usr/local/bin/php-entry"]'
assert_file_contains "$file" 'CMD ["php-fpm"]'

if grep -Eq '^ADD https?://|Scriptomatic/master/' "$file"; then
  fail "PHP runtime must not use remote ADD or the stale Scriptomatic master ref"
fi

pass "PHP selected-version Alpine runtime and Scriptomatic bootstrap contract"
