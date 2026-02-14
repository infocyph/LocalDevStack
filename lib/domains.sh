#!/usr/bin/env bash
# shellcheck shell=bash

setup_domain() {
  tools_exec_raw mkhost --RESET
  tools_exec mkhost
  local php_prof svr_prof node_prof
  php_prof=$(tools_exec_raw mkhost --ACTIVE_PHP_PROFILE || true)
  svr_prof=$(tools_exec_raw mkhost --APACHE_ACTIVE || true)
  node_prof=$(tools_exec_raw mkhost --ACTIVE_NODE_PROFILE || true)
  [[ -n $php_prof ]] && modify_profiles add "$php_prof"
  [[ -n $svr_prof ]] && modify_profiles add "$svr_prof"
  [[ -n $node_prof ]] && modify_profiles add "$node_prof"
  tools_exec_raw mkhost --RESET
  dc_up -d
  http_reload
}

rmhost() {
  tools_exec_raw rmhost --RESET
  tools_exec rmhost
  local php_prof svr_prof node_prof
  php_prof=$(tools_exec_raw rmhost --ACTIVE_PHP_PROFILE || true)
  svr_prof=$(tools_exec_raw rmhost --APACHE_ACTIVE || true)
  node_prof=$(tools_exec_raw rmhost --ACTIVE_NODE_PROFILE || true)
  [[ -n $php_prof ]] && modify_profiles add "$php_prof"
  [[ -n $svr_prof ]] && modify_profiles add "$svr_prof"
  [[ -n $node_prof ]] && modify_profiles add "$node_prof"
  tools_exec_raw rmhost --RESET
  __EXTRAS_LOADED=0
  dc_up -d
  http_reload
}
