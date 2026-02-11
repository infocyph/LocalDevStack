# lds lib: net
# shellcheck shell=bash

net_list() { docker network ls; }
net_inspect() { docker network inspect "$1"; }
