# lds lib: diag
# shellcheck shell=bash
# Requires lib/docker_exec.sh

diag_dns() { tools_exec sh -lc "dig +short '$1' || true; getent hosts '$1' || true"; }
diag_route() { tools_exec sh -lc "ip r; echo; ip a"; }
diag_tcp() { tools_exec sh -lc "nc -vz -w 3 '$1' '$2'"; }
diag_http_head() { tools_exec sh -lc "curl -vkI '$1'"; }
diag_tls() { tools_exec sh -lc "openssl s_client -connect '$1:$2' -servername '$1' -showcerts </dev/null"; }
