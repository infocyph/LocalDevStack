#!/usr/bin/env bash
# shellcheck shell=bash
# Generated from lds_X refactor (lib stage)

# Secrets wrapper around senv inside SERVER_TOOLS.

lds_senv() { tools_exec senv "$@"; }

lds_secrets_status() { lds_senv info; }
lds_secrets_init()   { lds_senv init "$@"; }
lds_secrets_edit()   { lds_senv edit "$@"; }
lds_secrets_pull()   { lds_senv pull "$@"; }
lds_secrets_push()   { lds_senv push "$@"; }

