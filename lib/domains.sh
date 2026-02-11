# lds lib: domains
# shellcheck shell=bash
# Requires lib/docker_exec.sh and lib/http.sh

mkhost() { docker exec SERVER_TOOLS mkhost "$@"; }

delhost() { docker exec SERVER_TOOLS delhost "$@"; }

setup_domain() {
  mkhost --RESET
  docker exec -it SERVER_TOOLS mkhost
  local php_prof svr_prof node_prof
  php_prof=$(mkhost --ACTIVE_PHP_PROFILE || true)
  svr_prof=$(mkhost --APACHE_ACTIVE || true)
  node_prof=$(mkhost --ACTIVE_NODE_PROFILE || true)
  [[ -n $php_prof ]] && modify_profiles add "$php_prof"
  [[ -n $svr_prof ]] && modify_profiles add "$svr_prof"
  [[ -n $node_prof ]] && modify_profiles add "$node_prof"
  mkhost --RESET
  dc_up -d
  http_reload
}

