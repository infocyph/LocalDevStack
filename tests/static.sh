#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

mapfile -t shell_files < <(
  {
    printf '%s\n' "$ROOT/lds"
    find "$ROOT/bin" -maxdepth 1 -type f -print
    find "$ROOT/tests" -type f -name '*.sh' -print
  } | sort -u
)

(("${#shell_files[@]}" > 0)) || fail "no shell files found"

for file in "${shell_files[@]}"; do
  bash -n "$file"
done
pass "bash syntax"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error -x "${shell_files[@]}"
  pass "ShellCheck error-level gate"

  mapfile -t test_shell_files < <(find "$ROOT/tests" -type f -name '*.sh' -print | sort)
  shellcheck --severity=warning -x "${test_shell_files[@]}"
  pass "ShellCheck warning-level gate for tests"
fi

while IFS= read -r file; do
  if grep -Iq . "$file" && grep -q $'\r$' "$file"; then
    fail "CRLF detected in shell file: $file"
  fi
done < <(printf '%s\n' "${shell_files[@]}")

pass "shell files use LF endings"
