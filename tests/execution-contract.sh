#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

# Capture the pre-refactor execution contract. Some assertions intentionally
# describe behavior that later batches will replace (forced TTY, argv flattening,
# and core container uppercasing). Change those assertions only together with the
# implementation batch that deliberately changes the contract.

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/execution.log"

run_case() {
  : >"$log"
  (
    set -euo pipefail
    export EXECUTION_TEST_LOG="$log"
    export CYAN='' YELLOW='' RED='' GREEN='' NC='' QUIET=0 VERBOSE=0
    die() { printf 'die:%s\n' "$*" >>"$EXECUTION_TEST_LOG"; return 64; }
    lds_project() { printf '%s' testproject; }
    effective_ai_runtime() { printf '%s' cpu; }
    ai_service_for_runtime() { printf '%s' llm-ollama; }
    docker_compose() { printf 'compose:' >>"$EXECUTION_TEST_LOG"; printf ' <%s>' "$@" >>"$EXECUTION_TEST_LOG"; printf '\n' >>"$EXECUTION_TEST_LOG"; }
    _project_tools_container_running() { printf '%s' SERVER_TOOLS; }

    docker() {
      printf 'docker:' >>"$EXECUTION_TEST_LOG"
      printf ' <%s>' "$@" >>"$EXECUTION_TEST_LOG"
      printf '\n' >>"$EXECUTION_TEST_LOG"

      case "${1:-} ${2:-} ${3:-}" in
        "inspect -f {{.State.Running}}")
          printf '%s\n' true
          ;;
        "inspect  "*)
          return 0
          ;;
      esac

      if [[ "${1:-}" == exec ]]; then
        case " $* " in
          *" domain-which --list-domains "*)
            printf '%s\n' app.local
            ;;
          *" domain-which --app --quiet app.local "*)
            printf '%s\n' node
            ;;
          *" domain-which --container --quiet app.local "*)
            printf '%s\n' NODE
            ;;
          *" domain-which --docroot --quiet app.local "*)
            printf '%s\n' /srv/app/public
            ;;
        esac
      fi
    }

    # shellcheck source=lib/services.sh
    source "$ROOT/lib/services.sh"
    "$@"
  )
}

case_cli_command() {
  cmd_cli demo-container printf '%s %s' 'hello world' tail
}
run_case case_cli_command
assert_file_contains "$log" 'docker: <inspect> <demo-container>'
assert_file_contains "$log" 'docker: <inspect> <-f> <{{.State.Running}}> <demo-container>'
assert_file_contains "$log" 'docker: <exec> <-it> <demo-container> <sh> <-lc>'
assert_file_contains "$log" '<printf %s %s hello world tail>'
pass "baseline: lds cli explicit command validates container, forces TTY, and flattens argv"

case_cli_shell() {
  cmd_cli demo-container
}
run_case case_cli_shell
assert_file_contains "$log" 'docker: <exec> <-it> <demo-container> <sh> <-lc>'
assert_file_contains "$log" 'exec bash --login'
pass "baseline: lds cli without command opens an interactive login shell"

case_core_domain() {
  cmd_core app.local
}
run_case case_core_domain
assert_file_contains "$log" 'docker: <exec> <SERVER_TOOLS> <domain-which> <--app> <--quiet> <app.local>'
assert_file_contains "$log" 'docker: <exec> <SERVER_TOOLS> <domain-which> <--container> <--quiet> <app.local>'
assert_file_contains "$log" 'docker: <exec> <-it> <NODE> <bash> <-lc>'
assert_file_contains "$log" 'cd "/app"'
pass "baseline: lds core resolves a domain through server-tools and forces Node /app"

case_core_container() {
  cmd_core mixedCase-container
}
run_case case_core_container
assert_file_contains "$log" 'docker: <exec> <-it> <MIXEDCASE-CONTAINER> <sh> <-lc> <exec bash -i || exec sh>'
pass "baseline: lds core raw container fallback uppercases the target"

case_stack_exec_command() {
  resolve_service() { printf '%s' php84; }
  cmd_exec PHP84 php -r 'echo "ok";'
}
run_case case_stack_exec_command
assert_file_contains "$log" 'compose: <exec> <php84> <php> <-r> <echo "ok";>'
pass "baseline: lds stack exec/cmd_exec preserves explicit command argv through Compose"

case_stack_exec_shell() {
  resolve_service() { printf '%s' php84; }
  cmd_exec PHP84
}
run_case case_stack_exec_shell
assert_file_contains "$log" 'compose: <exec> <php84> <sh> <-lc> <command -v bash >/dev/null 2>&1 && exec bash || exec sh>'
pass "baseline: lds stack exec/cmd_exec opens Bash-or-sh when no command is provided"

case_tools_exec() {
  cmd_tools exec printf '%s %s' 'hello world' tail
}
run_case case_tools_exec
assert_file_contains "$log" 'docker: <exec> <-it> <SERVER_TOOLS> <sh> <-lc> <printf %s %s hello world tail>'
pass "baseline: lds tools exec forces TTY and flattens command argv"

case_tools_shell() {
  docker_shell() { printf 'docker-shell:%s\n' "$1" >>"$EXECUTION_TEST_LOG"; }
  cmd_tools sh
}
run_case case_tools_shell
assert_file_contains "$log" 'docker-shell:SERVER_TOOLS'
pass "baseline: lds tools sh delegates to the common docker_shell helper"

assert_file_contains "$ROOT/lds" 'exec) cmd_exec "$@" ;;'
assert_file_contains "$ROOT/lds" 'cmd_stack "$@"'
pass "baseline: grouped stack exec and top-level dispatch remain wired"

printf 'Execution baseline contract complete.\n'
