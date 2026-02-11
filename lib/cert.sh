#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Certificate helpers (mkcert/certify integration placeholders).
# lds_X currently ships CA trust flows in ca.sh; cert generation is handled elsewhere in your stack.

lds_cert_expiry() {
  local pem="$1"
  tools_exec sh -lc "openssl x509 -in '$pem' -noout -enddate" || return $?
}

lds_cert_verify() {
  local host="$1" port="${2:-443}"
  lds_diag_tls "$host" "$port" >/dev/null
}

