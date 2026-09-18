#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools_image="infocyph/tools:latest"

docker pull "$tools_image" >/dev/null
versions="$(docker run --rm --entrypoint cat "$tools_image" /etc/share/runtime-versions.json)"

php_version="$(jq -r '.php.active[0] // empty' <<<"$versions")"
node_version="$(jq -r '.node.active[0] // empty' <<<"$versions")"
[[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || {
  printf 'Invalid active PHP version from Tools: %s\n' "$php_version" >&2
  exit 1
}
[[ "$node_version" =~ ^[0-9]+([.][0-9]+([.][0-9]+)?)?$ ]] || {
  printf 'Invalid active Node version from Tools: %s\n' "$node_version" >&2
  exit 1
}

php_key="${php_version/./}"
php_image="localdevstack-php:compat-smoke"
node_image="localdevstack-node:compat-smoke"

printf 'Building selected PHP runtime: %s\n' "$php_version"
docker build --pull   -f "$ROOT/docker/dockerfiles/php.Dockerfile"   --build-arg "PHP_VERSION=$php_version"   --build-arg "PHP_PROFILE_KEY=$php_key"   --build-arg "UID=1000"   --build-arg "GID=1000"   --build-arg "USERNAME=dockery"   --build-arg "SCRIPTOMATIC_REF=main"   -t "$php_image"   "$ROOT/docker/dockerfiles"

docker run --rm --entrypoint sh "$php_image" -ec '
  php -v
  php-fpm -t
  command -v gitx >/dev/null
  command -v chromacat >/dev/null
  gitx --version
  chromacat --version
'

printf 'Building selected Node runtime: %s\n' "$node_version"
docker build --pull   -f "$ROOT/docker/dockerfiles/node.Dockerfile"   --build-arg "NODE_VERSION=$node_version"   --build-arg "UID=1000"   --build-arg "GID=1000"   --build-arg "USERNAME=dockery"   --build-arg "SCRIPTOMATIC_REF=main"   -t "$node_image"   "$ROOT/docker/dockerfiles"

docker run --rm --entrypoint sh "$node_image" -ec '
  node --version
  npm --version
  command -v gitx >/dev/null
  command -v chromacat >/dev/null
  gitx --version
  chromacat --version
'

printf 'Runtime build smoke passed: PHP %s / Node %s\n' "$php_version" "$node_version"
