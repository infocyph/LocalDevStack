# lds lib: validate
# shellcheck shell=bash
# Requires lib/docker.sh

validate_compose() { docker_compose config >/dev/null; }
validate_profiles() { :; } # placeholder
