# lds lib: help
# shellcheck shell=bash

help_list_bin() {
  local bin_dir="${1:?}"
  (cd "$bin_dir" 2>/dev/null && ls -1 lds-* 2>/dev/null | sed 's/^lds-//' | sort -u) || true
}
