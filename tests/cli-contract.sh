#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

help_output="$("$ROOT/lds" help)"
assert_contains "$help_output" "LocalDevStack"
assert_contains "$help_output" "Stack"
assert_contains "$help_output" "Domain"
assert_contains "$help_output" "Setup"
pass "lds help"

markdown_output="$("$ROOT/lds" help --markdown)"
assert_contains "$markdown_output" "# LocalDevStack"
assert_contains "$markdown_output" "lds stack up"
pass "lds markdown help"

global_help="$("$ROOT/lds" --help)"
assert_contains "$global_help" "LocalDevStack"
pass "lds --help"

code=0
"$ROOT/lds" >/tmp/lds-noargs.out 2>/tmp/lds-noargs.err || code=$?
[[ "$code" -eq 1 ]] || fail "no-argument invocation must exit 1; got $code"
grep -q "LocalDevStack" /tmp/lds-noargs.out || fail "no-argument invocation must print help"
pass "no-argument behavior"

tmpbin="$(mktemp -d)"
trap 'rm -rf "$tmpbin" /tmp/lds-noargs.out /tmp/lds-noargs.err' EXIT
cat >"$tmpbin/docker" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$tmpbin/docker"

stack_help="$(PATH="$tmpbin:$PATH" "$ROOT/lds" stack help)"
assert_contains "$stack_help" "LocalDevStack"
pass "grouped stack help routing"

assert_file_contains "$ROOT/lds" 'exec "$DIR/bin/tool-runner" "$cmd" "$@"'
pass "unknown command fallback remains delegated to tool-runner"
