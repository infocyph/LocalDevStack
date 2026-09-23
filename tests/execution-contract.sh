#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

# This contract evolves batch-by-batch. Assertions for a surface are updated
# only when that surface deliberately migrates onto the shared executor.

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
    err() { printf 'err:%s\n' "$*" >>"$EXECUTION_TEST_LOG"; }
    lds_project() { printf '%s' testproject; }
    effective_ai_runtime() { printf '%s' cpu; }
    ai_service_for_runtime() { printf '%s' llm-ollama; }
    _project_tools_container_running() { printf '%s' SERVER_TOOLS; }

    docker_compose() {
      printf 'compose:' >>"$EXECUTION_TEST_LOG"
      printf ' <%s>' "$@" >>"$EXECUTION_TEST_LOG"
      printf '\n' >>"$EXECUTION_TEST_LOG"

      if [[ "${1:-}" == config && "${2:-}" == --services ]]; then
        printf '%s\n' php84 node multi
        return 0
      fi
      if [[ "${1:-}" == ps && "${2:-}" == -a && "${3:-}" == -q ]]; then
        case "${4:-}" in
          php84) printf '%s\n' cid-php84 ;;
          node) printf '%s\n' cid-node ;;
          multi) printf '%s\n' cid-one cid-two ;;
        esac
        return 0
      fi
      return 0
    }

    docker() {
      printf 'docker:' >>"$EXECUTION_TEST_LOG"
      printf ' <%s>' "$@" >>"$EXECUTION_TEST_LOG"
      printf '\n' >>"$EXECUTION_TEST_LOG"

      if [[ "${1:-}" == inspect && "${2:-}" == -f ]]; then
        case "${3:-}|${4:-}" in
          "{{.Id}}|demo-container") printf '%s\n' cid-demo ;;
          "{{.Id}}|mixedCase-container") printf '%s\n' cid-mixed ;;
          "{{.Id}}|NODE") printf '%s\n' cid-node ;;
          "{{.Id}}|stopped-container") printf '%s\n' cid-stopped ;;
          "{{.Id}}|"*) return 1 ;;
          "{{.Name}}|cid-demo") printf '%s\n' /demo-container ;;
          "{{.Name}}|cid-mixed") printf '%s\n' /mixedCase-container ;;
          "{{.Name}}|cid-node") printf '%s\n' /NODE ;;
          "{{.Name}}|cid-php84") printf '%s\n' /PHP84 ;;
          "{{.Name}}|cid-one") printf '%s\n' /ONE ;;
          "{{.Name}}|cid-two") printf '%s\n' /TWO ;;
          "{{.Name}}|cid-stopped") printf '%s\n' /stopped-container ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-demo") printf '%s\n' ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-mixed") printf '%s\n' ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-node") printf '%s\n' node ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-stopped") printf '%s\n' ;;
          "{{.State.Running}}|cid-demo") printf '%s\n' true ;;
          "{{.State.Running}}|cid-mixed") printf '%s\n' true ;;
          "{{.State.Running}}|cid-node") printf '%s\n' true ;;
          "{{.State.Running}}|cid-php84") printf '%s\n' true ;;
          "{{.State.Running}}|cid-stopped") printf '%s\n' false ;;
          "{{.State.Running}}|"*) printf '%s\n' true ;;
        esac
        return 0
      fi

      if [[ "${1:-}" == inspect && "${2:-}" != -f ]]; then
        return 0
      fi

      if [[ "${1:-}" == exec ]]; then
        case " $* " in
          *" domain-which --list-domains "*)
            printf '%s\n' app.local php.local
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
          *" domain-which --app --quiet php.local "*)
            printf '%s\n' php
            ;;
          *" domain-which --container --quiet php.local "*)
            printf '%s\n' php84
            ;;
          *" domain-which --docroot --quiet php.local "*)
            printf '%s\n' /srv/php/public
            ;;
          *" domain-which --app --quiet fallback.local "*)
            printf '%s\n' php
            ;;
          *" domain-which --container --quiet fallback.local "*)
            printf '%s\n' php84
            ;;
          *" domain-which --docroot --quiet fallback.local "*)
            printf '%s\n' /missing/docroot
            ;;
          *" cid-node test -d /app "*)
            return 0
            ;;
          *" cid-php84 test -d /srv/php/public "*)
            return 0
            ;;
          *" cid-php84 test -d /missing/docroot "*)
            return 1
            ;;
          *" cid-php84 test -d /app "*)
            return 0
            ;;
          *" cid-demo sh -lc command -v bash >/dev/null 2>&1 "*|*" cid-mixed sh -lc command -v bash >/dev/null 2>&1 "*|*" cid-node sh -lc command -v bash >/dev/null 2>&1 "*|*" cid-php84 sh -lc command -v bash >/dev/null 2>&1 "*)
            return 0
            ;;
        esac
        return 0
      fi
    }

    # shellcheck source=lib/container-exec.sh
    source "$ROOT/lib/container-exec.sh"
    # shellcheck source=lib/services.sh
    source "$ROOT/lib/services.sh"
    "$@"
  )
}

case_cli_command() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_cli demo-container -- printf '%s %s' 'hello world' '$(danger)'
}
run_case case_cli_command
assert_file_contains "$log" 'docker: <inspect> <-f> <{{.Id}}> <demo-container>'
assert_file_contains "$log" 'docker: <exec> <cid-demo> <printf> <%s %s> <hello world> <$(danger)>'
if grep -Fq '<sh> <-lc>' "$log"; then
  fail "lds cli explicit command still reparses argv through a shell"
fi
pass "batch 2: lds cli preserves explicit command argv without forcing TTY"

case_cli_piped_command() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 0; }
  cmd_cli demo-container cat
}
run_case case_cli_piped_command
assert_file_contains "$log" 'docker: <exec> <-i> <cid-demo> <cat>'
pass "batch 2: lds cli keeps piped stdin without allocating TTY"

case_cli_service() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_cli php84 php -v
}
run_case case_cli_service
assert_file_contains "$log" 'compose: <config> <--services>'
assert_file_contains "$log" 'compose: <ps> <-a> <-q> <php84>'
assert_file_contains "$log" 'docker: <exec> <cid-php84> <php> <-v>'
pass "batch 2: lds cli resolves current-project Compose service names"

case_cli_shell() {
  cmd_cli demo-container
}
run_case case_cli_shell
assert_file_contains "$log" 'docker: <exec> <-it> <cid-demo> <bash> <--login>'
pass "batch 2: lds cli without command opens the shared interactive shell"

set +e
run_case cmd_cli stopped-container >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 69 ]] || fail "lds cli stopped target returned $rc instead of 69"
assert_file_contains "$log" 'err:Container is not running: cid-stopped'
pass "batch 2: lds cli reports stopped targets"

set +e
run_case cmd_cli missing-container >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 66 ]] || fail "lds cli missing target returned $rc instead of 66"
assert_file_contains "$log" 'err:Container or current-project service not found: missing-container'
pass "batch 2: lds cli reports missing targets"

set +e
run_case cmd_cli multi >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 65 ]] || fail "lds cli ambiguous service returned $rc instead of 65"
assert_file_contains "$log" 'err:Service resolves to multiple containers: multi'
pass "batch 2: lds cli rejects ambiguous service targets"

case_core_node_domain() {
  cmd_core app.local
}
run_case case_core_node_domain
assert_file_contains "$log" 'docker: <exec> <SERVER_TOOLS> <domain-which> <--app> <--quiet> <app.local>'
assert_file_contains "$log" 'docker: <exec> <-it> <--workdir> </app> <cid-node> <bash> <--login>'
pass "batch 3: lds core resolves Node domains and opens /app through the shared shell helper"

case_core_php_domain() {
  cmd_core php.local
}
run_case case_core_php_domain
assert_file_contains "$log" 'docker: <exec> <-it> <--workdir> </srv/php/public> <cid-php84> <bash> <--login>'
pass "batch 3: lds core preserves resolved PHP document root"

case_core_docroot_fallback() {
  cmd_core fallback.local
}
run_case case_core_docroot_fallback
assert_file_contains "$log" 'docker: <exec> <cid-php84> <test> <-d> </missing/docroot>'
assert_file_contains "$log" 'docker: <exec> <-it> <--workdir> </app> <cid-php84> <bash> <--login>'
pass "batch 3: lds core falls back from missing docroot to /app"

case_core_domain_command() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_core app.local -- node -e 'console.log("hello world")'
}
run_case case_core_domain_command
assert_file_contains "$log" 'docker: <exec> <--workdir> </app> <cid-node> <node> <-e> <console.log("hello world")>'
pass "batch 3: lds core executes domain commands as exact argv in the application workdir"

case_core_service() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_core php84 php -v
}
run_case case_core_service
assert_file_contains "$log" 'compose: <ps> <-a> <-q> <php84>'
assert_file_contains "$log" 'docker: <exec> <cid-php84> <php> <-v>'
pass "batch 3: lds core delegates service targets to the shared resolver"

case_core_container() {
  cmd_core mixedCase-container
}
run_case case_core_container
assert_file_contains "$log" 'docker: <inspect> <-f> <{{.Id}}> <mixedCase-container>'
assert_file_contains "$log" 'docker: <exec> <-it> <cid-mixed> <bash> <--login>'
if grep -Fq 'MIXEDCASE-CONTAINER' "$log"; then
  fail "lds core still uppercases explicit container targets"
fi
pass "batch 3: lds core preserves explicit mixed-case container targets"

case_core_single_domain() {
  _core_domain_list() { printf '%s\n' app.local; }
  cmd_core
}
run_case case_core_single_domain
assert_file_contains "$log" 'docker: <exec> <-it> <--workdir> </app> <cid-node> <bash> <--login>'
pass "batch 3: lds core auto-selects the only discovered domain"

set +e
run_case cmd_core >"$tmp/core-nontty.out" 2>"$tmp/core-nontty.err"
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "lds core non-TTY multi-domain selection returned $rc instead of 64"
grep -Fq 'app.local' "$tmp/core-nontty.err" || fail "non-TTY domain list omitted app.local"
grep -Fq 'php.local' "$tmp/core-nontty.err" || fail "non-TTY domain list omitted php.local"
assert_file_contains "$log" 'err:No TTY to prompt. Use: lds core <domain>'
pass "batch 3: lds core lists domains and fails actionably without a TTY"

case_stack_exec_command() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_exec PHP84 -- php -r 'echo "ok";'
}
run_case case_stack_exec_command
assert_file_contains "$log" 'docker: <exec> <cid-php84> <php> <-r> <echo "ok";>'
if grep -Fq 'compose: <exec>' "$log"; then
  fail "lds stack exec still bypasses the shared container executor"
fi
pass "batch 4: lds stack exec remains service-only and preserves command argv"

case_stack_exec_shell() {
  cmd_exec PHP84
}
run_case case_stack_exec_shell
assert_file_contains "$log" 'docker: <exec> <-it> <cid-php84> <bash> <--login>'
pass "batch 4: lds stack exec uses the shared interactive shell helper"

case_tools_exec() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_tools exec -- printf '%s %s' 'hello world' '$(danger)'
}
run_case case_tools_exec
assert_file_contains "$log" 'docker: <exec> <SERVER_TOOLS> <printf> <%s %s> <hello world> <$(danger)>'
if grep -Fq '<sh> <-lc> <printf %s %s hello world' "$log"; then
  fail "lds tools exec still flattens argv through a shell"
fi
pass "batch 4: lds tools exec preserves exact argv through the shared executor"

case_tools_shell() {
  cmd_tools sh
}
run_case case_tools_shell
assert_file_contains "$log" 'docker: <exec> <-it> <SERVER_TOOLS> <bash> <--login>'
pass "batch 4: lds tools sh uses the shared interactive shell helper"

case_tools_file() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_tools file '/app/path with spaces.txt'
}
run_case case_tools_file
assert_file_contains "$log" '<sh> <-lc>'
assert_file_contains "$log" '<sh> </app/path with spaces.txt>'
pass "batch 4: lds tools file passes paths as shell positional argv rather than interpolating them"

assert_file_contains "$ROOT/lib/services.sh" 'docker exec -it "$ctr" lazydocker'
pass "batch 4: support ui remains a specialized interactive TUI path"

assert_file_contains "$ROOT/lds" 'exec) cmd_exec "$@" ;;'
assert_file_contains "$ROOT/lds" 'cmd_stack "$@"'
pass "baseline: grouped stack exec and top-level dispatch remain wired"

printf 'Execution contract complete.\n'
