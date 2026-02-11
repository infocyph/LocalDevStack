#!/usr/bin/env bash

# Help rendering and command discovery

lds_commands_discover() {
  local bin_dir="${1:-$DIR/bin}"
  [[ -d "$bin_dir" ]] || return 0
  find "$bin_dir" -maxdepth 1 -type f -name 'lds-*' -printf '%f\n' | sed 's/^lds-//' | LC_ALL=C sort -u
}
