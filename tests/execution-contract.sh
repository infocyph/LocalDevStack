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

      if [[ "${1:-}" == ps && "${2:-}" == --format ]]; then
        printf '%s\n' demo-container external-worker worker.local
        return 0
      fi

      if [[ "${1:-}" == inspect && "${2:-}" == -f ]]; then
        case "${3:-}|${4:-}" in
          "{{.Id}}|demo-container") printf '%s\n' cid-demo ;;
          "{{.Id}}|mixedCase-container") printf '%s\n' cid-mixed ;;
          "{{.Id}}|worker.local") printf '%s\n' cid-domainlike ;;
          "{{.Id}}|NODE") printf '%s\n' cid-node ;;
          "{{.Id}}|node") printf '%s\n' cid-node-container ;;
          "{{.Id}}|stopped-container") printf '%s\n' cid-stopped ;;
          "{{.Id}}|"*) return 1 ;;
          "{{.Name}}|cid-demo") printf '%s\n' /demo-container ;;
          "{{.Name}}|cid-mixed") printf '%s\n' /mixedCase-container ;;
          "{{.Name}}|cid-domainlike") printf '%s\n' /worker.local ;;
          "{{.Name}}|cid-node") printf '%s\n' /NODE ;;
          "{{.Name}}|cid-node-container") printf '%s\n' /node ;;
          "{{.Name}}|cid-php84") printf '%s\n' /PHP84 ;;
          "{{.Name}}|cid-one") printf '%s\n' /ONE ;;
          "{{.Name}}|cid-two") printf '%s\n' /TWO ;;
          "{{.Name}}|cid-stopped") printf '%s\n' /stopped-container ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-demo") printf '\n' ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-mixed") printf '\n' ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-domainlike") printf '\n' ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-node") printf '%s\n' node ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-node-container") printf '%s\n' external-node ;;
          "{{ index .Config.Labels \"com.docker.compose.service\" }}|cid-stopped") printf '\n' ;;
          "{{.State.Running}}|cid-demo") printf '%s\n' true ;;
          "{{.State.Running}}|cid-mixed") printf '%s\n' true ;;
          "{{.State.Running}}|cid-domainlike") printf '%s\n' true ;;
          "{{.State.Running}}|cid-node") printf '%s\n' true ;;
          "{{.State.Running}}|cid-php84") printf '%s\n' true ;;
          "{{.State.Running}}|cid-stopped") printf '%s\n' false ;;
          "{{.State.Running}}|demo-container") printf '%s\n' true ;;
          "{{.State.Running}}|mixedCase-container") printf '%s\n' true ;;
          "{{.State.Running}}|worker.local") printf '%s\n' true ;;
          "{{.State.Running}}|stopped-container") printf '%s\n' false ;;
          "{{.State.Running}}|node") printf '%s\n' true ;;
          "{{.State.Running}}|cid-node-container") printf '%s\n' true ;;
          "{{.State.Running}}|SERVER_TOOLS") printf '%s\n' true ;;
          "{{.State.Running}}|billing"|"{{.State.Running}}|missing-shell"|"{{.State.Running}}|php:8.4-alpine") return 1 ;;
          "{{.State.Running}}|"*) printf '%s\n' true ;;
        esac
        return 0
      fi

      if [[ "${1:-}" == inspect && "${2:-}" != -f ]]; then
        return 0
      fi

      if [[ "${1:-}" == exec ]]; then
        if [[ "${2:-}" == SERVER_TOOLS && "${3:-}" == sh && "${4:-}" == -c ]]; then
          case "${7:-}" in
            /app/billing) return 0 ;;
            /app/missing-shell|/app/php:8.4-alpine) return 1 ;;
          esac
          if [[ "${5:-}" == *'for path in /app/'* ]]; then
            printf '%s\n' billing node
            return 0
          fi
        fi
        if [[ " $* " == *" signal-test "* ]]; then
          return 130
        fi
        case " $* " in
          *" domain-which --list-domains "*)
            printf '%s\n' app.local php.local fallback.local
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

force_interactive_tty() {
  _container_stdin_is_tty() { return 0; }
  _container_stdout_is_tty() { return 0; }
}

case_shell_resolve_domain() {
  _shell_resolve_target app.local
  printf 'shell-context:%s|%s|%s|%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_DOMAIN" "$_SHELL_APP" "$_SHELL_CONTAINER_ID" "$_SHELL_WORKDIR" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_resolve_domain
assert_file_contains "$log" 'shell-context:domain|app.local|node|cid-node|/app'
pass "shell batch 1: exact discovered domain resolves application container and cwd"

case_shell_resolve_tools() {
  _shell_resolve_target tools
  printf 'shell-context:%s|%s|%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_SERVICE" "$_SHELL_CONTAINER_ID" "$_SHELL_WORKDIR" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_resolve_tools
assert_file_contains "$log" 'shell-context:tools|server-tools|SERVER_TOOLS|'
pass "shell batch 1: reserved tools target resolves server-tools"

case_shell_resolve_service() {
  _shell_resolve_target php84
  printf 'shell-context:%s|%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_SERVICE" "$_SHELL_CONTAINER_ID" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_resolve_service
assert_file_contains "$log" 'shell-context:service|php84|cid-php84'
pass "shell batch 1: exact current-project service resolves before container fallback"

case_shell_resolve_container() {
  _shell_resolve_target demo-container
  printf 'shell-context:%s|%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_CONTAINER_ID" "$_SHELL_CONTAINER_NAME" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_resolve_container
assert_file_contains "$log" 'shell-context:container|cid-demo|demo-container'
pass "shell batch 1: exact container resolves without case rewriting"

case_shell_resolve_app() {
  _shell_resolve_target billing
  printf 'shell-context:%s|%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_CONTAINER_ID" "$_SHELL_WORKDIR" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_resolve_app
assert_file_contains "$log" 'shell-context:app|SERVER_TOOLS|/app/billing'
pass "shell batch 1: unresolved target falls back to direct server-tools /app child"

case_shell_qualified_targets() {
  _shell_resolve_target domain:php.local
  printf 'qualified:%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_DOMAIN" >>"$EXECUTION_TEST_LOG"
  _shell_resolve_target service:node
  printf 'qualified:%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_SERVICE" >>"$EXECUTION_TEST_LOG"
  _shell_resolve_target container:mixedCase-container
  printf 'qualified:%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_CONTAINER_NAME" >>"$EXECUTION_TEST_LOG"
  _shell_resolve_target app:billing
  printf 'qualified:%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_WORKDIR" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_qualified_targets
assert_file_contains "$log" 'qualified:domain|php.local'
assert_file_contains "$log" 'qualified:service|node'
assert_file_contains "$log" 'qualified:container|mixedCase-container'
assert_file_contains "$log" 'qualified:app|/app/billing'
pass "shell batch 1: qualified selectors bypass normal precedence"

set +e
run_case _shell_resolve_target app:../escape >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "shell app traversal returned $rc instead of 64"
pass "shell batch 1: /app fallback rejects path traversal"

set +e
run_case _shell_resolve_target missing-shell >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 66 ]] || fail "missing shell target returned $rc instead of 66"
assert_file_contains "$log" 'err:Shell target not found: missing-shell'
pass "shell batch 1: unresolved targets return one final actionable not-found error"

set +e
run_case _shell_resolve_target php:8.4-alpine >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 66 ]] || fail "image-like shell target returned $rc instead of 66"
if grep -Fq '<run>' "$log"; then
  fail "lds shell resolver attempted to instantiate an image"
fi
pass "shell batch 1: image-like targets are not implicitly instantiated"

case_shell_menu_build() {
  _shell_menu_build
  local i
  for ((i = 0; i < ${#_SHELL_MENU_NAME[@]}; i++)); do
    printf 'menu:%s|%s|%s\n' "${_SHELL_MENU_KIND[$i]}" "${_SHELL_MENU_NAME[$i]}" "${_SHELL_MENU_SELECTOR[$i]}" >>"$EXECUTION_TEST_LOG"
  done
}
run_case case_shell_menu_build
assert_file_contains "$log" 'menu:domain|app.local|domain:app.local'
assert_file_contains "$log" 'menu:app|billing|app:billing'
assert_file_contains "$log" 'menu:service|php84|service:php84'
assert_file_contains "$log" 'menu:container|demo-container|container:demo-container'
assert_file_contains "$log" 'menu:utility|tools|utility:tools'
pass "shell batch 2: grouped catalog includes domains apps services containers and tools"

case_shell_choose_number() {
  _shell_selector_is_tty() { return 0; }
  local choice
  choice="$(printf '4\n' | _shell_choose_target)"
  printf 'choice:%s\n' "$choice" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_choose_number
assert_file_contains "$log" 'choice:app:billing'
pass "shell batch 2: global numeric selector resolves across grouped categories"

case_shell_choose_name() {
  _shell_selector_is_tty() { return 0; }
  local choice
  choice="$(printf 'billing\n' | _shell_choose_target)"
  printf 'choice:%s\n' "$choice" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_choose_name
assert_file_contains "$log" 'choice:app:billing'
pass "shell batch 2: exact unique name selector resolves category target"

case_shell_choose_ambiguous_name() {
  _shell_selector_is_tty() { return 0; }
  local choice
  choice="$(printf 'node\nservice:node\n' | _shell_choose_target)"
  printf 'choice:%s\n' "$choice" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_choose_ambiguous_name
assert_file_contains "$log" 'choice:service:node'
pass "shell batch 2: ambiguous names require a qualified selector"

case_shell_menu_nontty() {
  _shell_selector_is_tty() { return 1; }
  _shell_choose_target
}
set +e
run_case case_shell_menu_nontty >"$tmp/shell-menu.out" 2>"$tmp/shell-menu.err"
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "bare shell non-TTY selector returned $rc instead of 64"
grep -Fq 'Applications / Domains' "$tmp/shell-menu.err" || fail "bare shell catalog omitted domain heading"
grep -Fq 'Application Directories' "$tmp/shell-menu.err" || fail "bare shell catalog omitted app heading"
grep -Fq 'Services' "$tmp/shell-menu.err" || fail "bare shell catalog omitted services heading"
grep -Fq 'Containers' "$tmp/shell-menu.err" || fail "bare shell catalog omitted containers heading"
grep -Fq 'Utilities' "$tmp/shell-menu.err" || fail "bare shell catalog omitted utilities heading"
assert_file_contains "$log" 'err:No TTY to prompt. Use: lds shell <target>'
pass "shell batch 2: bare shell prints grouped catalog and fails actionably without TTY"

case_shell_domain_shell() {
  force_interactive_tty
  cmd_shell app.local
}
run_case case_shell_domain_shell
assert_file_contains "$log" 'docker: <exec> <-it> <--workdir> </app> <cid-node> <bash> <--login>'
pass "shell batch 3: domain target opens application-aware interactive shell"

case_shell_app_shell() {
  force_interactive_tty
  cmd_shell billing
}
run_case case_shell_app_shell
assert_file_contains "$log" 'docker: <exec> <-it> <--workdir> </app/billing> <SERVER_TOOLS> <bash> <--login>'
pass "shell batch 3: app-directory fallback opens server-tools at matching /app child"

case_shell_service_command() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_shell php84 -- php -v
}
run_case case_shell_service_command
assert_file_contains "$log" 'docker: <exec> <cid-php84> <php> <-v>'
pass "shell batch 3: explicit command preserves argv for service target"

case_shell_expression() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_shell billing --shell 'printf "%s\n" "hello world" | cat'
}
run_case case_shell_expression
assert_file_contains "$log" 'docker: <exec> <--workdir> </app/billing> <SERVER_TOOLS> <sh> <-lc> <printf "%s\n" "hello world" | cat>'
pass "shell batch 3: --shell makes intentional shell parsing explicit"

case_shell_interactive_command() {
  force_interactive_tty
  cmd_shell tools --interactive lazydocker
}
run_case case_shell_interactive_command
assert_file_contains "$log" 'docker: <exec> <-it> <SERVER_TOOLS> <lazydocker>'
pass "shell batch 3: --interactive routes TUI argv through shared interactive helper"

case_shell_collision_precedence() {
  _shell_resolve_target node
  printf 'collision:unqualified|%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_CONTAINER_ID" >>"$EXECUTION_TEST_LOG"
  _shell_resolve_target container:node
  printf 'collision:qualified|%s|%s\n' "$_SHELL_TARGET_KIND" "$_SHELL_CONTAINER_ID" >>"$EXECUTION_TEST_LOG"
}
run_case case_shell_collision_precedence
assert_file_contains "$log" 'collision:unqualified|service|cid-node'
assert_file_contains "$log" 'collision:qualified|container|cid-node-container'
pass "shell batch 6: service precedence and qualified container escape are deterministic"

case_shell_domainlike_container_command() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_shell worker.local -- echo ok
}
run_case case_shell_domainlike_container_command
assert_file_contains "$log" 'docker: <exec> <cid-domainlike> <echo> <ok>'
if grep -Fq 'domain-which --app --quiet worker.local' "$log"; then
  fail "lds shell guessed hostname-shaped container was a domain"
fi
pass "shell batch 6: domain-like container names stay containers unless discovered"

case_shell_mixed_case_container() {
  force_interactive_tty
  cmd_shell mixedCase-container
}
run_case case_shell_mixed_case_container
assert_file_contains "$log" 'docker: <exec> <-it> <cid-mixed> <bash> <--login>'
if grep -Fq 'MIXEDCASE-CONTAINER' "$log"; then
  fail "lds shell rewrote mixed-case container target"
fi
pass "shell batch 6: exact mixed-case containers are preserved"

set +e
run_case cmd_shell multi >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 65 ]] || fail "lds shell ambiguous service returned $rc instead of 65"
assert_file_contains "$log" 'err:Service resolves to multiple containers: multi'
pass "shell batch 6: ambiguous service targets preserve exit 65"

set +e
run_case cmd_shell stopped-container >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 69 ]] || fail "lds shell stopped container returned $rc instead of 69"
assert_file_contains "$log" 'err:Container is not running: cid-stopped'
pass "shell batch 6: stopped target error wins before TTY validation"

set +e
run_case cmd_shell missing-shell >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 66 ]] || fail "lds shell missing target returned $rc instead of 66"
pass "shell batch 6: missing targets preserve exit 66"

case_shell_nontty_existing_target() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  cmd_shell demo-container
}
set +e
run_case case_shell_nontty_existing_target >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "lds shell non-TTY interactive target returned $rc instead of 64"
assert_file_contains "$log" 'err:Interactive container session requires a TTY'
pass "shell batch 6: interactive shell requires a real TTY"

case_shell_signal_exit() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_shell demo-container -- signal-test
}
set +e
run_case case_shell_signal_exit >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 130 ]] || fail "lds shell child exit 130 became $rc"
pass "shell batch 6: child Ctrl-C style exit status propagates unchanged"

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
  force_interactive_tty
  cmd_cli demo-container
}
run_case case_cli_shell
assert_file_contains "$log" 'docker: <exec> <-it> <cid-demo> <bash> <--login>'
pass "batch 2: lds cli without command opens the shared interactive shell"

case_cli_shell_nontty() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  cmd_cli demo-container
}
set +e
run_case case_cli_shell_nontty >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "lds cli non-TTY shell returned $rc instead of 64"
assert_file_contains "$log" 'err:Interactive container session requires a TTY'
pass "batch 6: lds cli rejects interactive shell without a TTY"

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

set +e
run_case cmd_cli >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "lds cli missing target returned $rc instead of 64"
assert_file_contains "$log" 'err:Usage: lds cli <service|container> [--] [command...]'
pass "batch 5: lds cli uses standardized usage exit"

case_core_node_domain() {
  force_interactive_tty
  cmd_core app.local
}
run_case case_core_node_domain
assert_file_contains "$log" 'docker: <exec> <SERVER_TOOLS> <domain-which> <--app> <--quiet> <app.local>'
assert_file_contains "$log" 'docker: <exec> <-it> <--workdir> </app> <cid-node> <bash> <--login>'
pass "batch 3: lds core resolves Node domains and opens /app through the shared shell helper"

case_core_php_domain() {
  force_interactive_tty
  cmd_core php.local
}
run_case case_core_php_domain
assert_file_contains "$log" 'docker: <exec> <-it> <--workdir> </srv/php/public> <cid-php84> <bash> <--login>'
pass "batch 3: lds core preserves resolved PHP document root"

case_core_docroot_fallback() {
  force_interactive_tty
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
  force_interactive_tty
  cmd_core mixedCase-container
}
run_case case_core_container
assert_file_contains "$log" 'docker: <inspect> <-f> <{{.Id}}> <mixedCase-container>'
assert_file_contains "$log" 'docker: <exec> <-it> <cid-mixed> <bash> <--login>'
if grep -Fq 'MIXEDCASE-CONTAINER' "$log"; then
  fail "lds core still uppercases explicit container targets"
fi
pass "batch 3: lds core preserves explicit mixed-case container targets"

case_core_domainlike_container() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_core worker.local -- echo ok
}
run_case case_core_domainlike_container
assert_file_contains "$log" 'docker: <inspect> <-f> <{{.Id}}> <worker.local>'
assert_file_contains "$log" 'docker: <exec> <cid-domainlike> <echo> <ok>'
if grep -Fq 'domain-which --app --quiet worker.local' "$log"; then
  fail "lds core guessed a hostname-shaped container was a domain"
fi
pass "batch 3: lds core distinguishes discovered domains from hostname-shaped containers"

case_core_single_domain() {
  force_interactive_tty
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
  force_interactive_tty
  cmd_exec PHP84
}
run_case case_stack_exec_shell
assert_file_contains "$log" 'docker: <exec> <-it> <cid-php84> <bash> <--login>'
pass "batch 4: lds stack exec uses the shared interactive shell helper"

set +e
run_case cmd_exec >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "lds stack exec missing service returned $rc instead of 64"
assert_file_contains "$log" 'err:Usage: lds stack exec <service> [--] [command...]'

set +e
run_case cmd_exec missing-service >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 66 ]] || fail "lds stack exec unknown service returned $rc instead of 66"
assert_file_contains "$log" 'err:Current-project service not found: missing-service'
pass "batch 5: lds stack exec uses standardized usage/not-found exits"

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

case_tools_shell_exec() {
  _container_stdin_is_tty() { return 1; }
  _container_stdout_is_tty() { return 1; }
  _container_stdin_has_data() { return 1; }
  cmd_tools shell-exec 'printf "%s\n" "hello world" | cat'
}
run_case case_tools_shell_exec
assert_file_contains "$log" 'docker: <exec> <SERVER_TOOLS> <sh> <-lc> <printf "%s\n" "hello world" | cat>'
pass "batch 4: lds tools shell-exec makes intentional shell parsing explicit"

case_tools_shell() {
  force_interactive_tty
  cmd_tools sh
}
run_case case_tools_shell
assert_file_contains "$log" 'docker: <exec> <-it> <SERVER_TOOLS> <bash> <--login>'
pass "batch 4: lds tools sh uses the shared interactive shell helper"

set +e
run_case cmd_tools exec >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || fail "lds tools exec missing command returned $rc instead of 64"
assert_file_contains "$log" 'err:Usage: lds tools exec [--] <command> [args...]'

case_tools_unavailable() {
  _project_tools_container_running() { return 1; }
  cmd_tools sh
}
set +e
run_case case_tools_unavailable >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 69 ]] || fail "lds tools unavailable container returned $rc instead of 69"
assert_file_contains "$log" 'err:server-tools container is not running for project: testproject'
pass "batch 5: lds tools uses standardized usage/unavailable exits"

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

case_tools_catalog_offline() {
  _project_tools_container_running() { return 1; }
  cmd_tools list >"$tmp/tools-catalog.out"
}
run_case case_tools_catalog_offline
assert_file_contains "$tmp/tools-catalog.out" 'gitx'
assert_file_contains "$tmp/tools-catalog.out" 'sqlitex'
assert_file_contains "$tmp/tools-catalog.out" 'chromacat'
assert_file_contains "$tmp/tools-catalog.out" 'netx'
assert_file_contains "$tmp/tools-catalog.out" 'lazydocker'
assert_file_contains "$tmp/tools-catalog.out" 'ffmpeg'
assert_file_contains "$tmp/tools-catalog.out" 'ffprobe'
assert_file_contains "$tmp/tools-catalog.out" 'sox'
assert_file_contains "$tmp/tools-catalog.out" 'soxi'
assert_file_contains "$tmp/tools-catalog.out" 'mkvmerge'
assert_file_contains "$tmp/tools-catalog.out" 'mkvinfo'
assert_file_contains "$tmp/tools-catalog.out" 'mkvextract'
assert_file_contains "$tmp/tools-catalog.out" 'mkvpropedit'
assert_file_contains "$tmp/tools-catalog.out" 'mediainfo'
assert_file_contains "$tmp/tools-catalog.out" 'xvidcore'
pass "tools catalog is discoverable without a running Tools container"

case_tools_direct_runner() {
  _tools_runner_exec() {
    printf 'tool-runner:' >>"$EXECUTION_TEST_LOG"
    printf ' <%s>' "$@" >>"$EXECUTION_TEST_LOG"
    printf '\n' >>"$EXECUTION_TEST_LOG"
  }
  cmd_tools gitx status --short
}
run_case case_tools_direct_runner
assert_file_contains "$log" 'tool-runner: <gitx> <status> <--short>'
pass "curated/non-reserved tools delegate argv to the temporary tool runner"

case_tools_explicit_runner() {
  _tools_runner_exec() {
    printf 'tool-runner:' >>"$EXECUTION_TEST_LOG"
    printf ' <%s>' "$@" >>"$EXECUTION_TEST_LOG"
    printf '\n' >>"$EXECUTION_TEST_LOG"
  }
  cmd_tools run sqlitex --db 'db path/app.db' tables
}
run_case case_tools_explicit_runner
assert_file_contains "$log" 'tool-runner: <sqlitex> <--db> <db path/app.db> <tables>'
pass "tools run provides an explicit collision-safe extension path"

case_tools_ui_runner() {
  _tools_runner_exec() {
    printf 'tool-runner:' >>"$EXECUTION_TEST_LOG"
    printf ' <%s>' "$@" >>"$EXECUTION_TEST_LOG"
    printf '\n' >>"$EXECUTION_TEST_LOG"
  }
  cmd_tools ui --debug
}
run_case case_tools_ui_runner
assert_file_contains "$log" 'tool-runner: <lazydocker> <--debug>'
pass "tools ui reuses the temporary runner for the Docker TUI"

case_ui_interactive() {
  force_interactive_tty
  cmd_ui
}
run_case case_ui_interactive
assert_file_contains "$log" 'docker: <exec> <-it> <SERVER_TOOLS> <lazydocker>'
pass "batch 4: support ui uses the shared interactive execution helper"

assert_file_contains "$ROOT/lds" 'exec) cmd_exec "$@" ;;'
assert_file_contains "$ROOT/lds" 'if _is_public_lds_command "$cmd"; then'
assert_file_contains "$ROOT/lds" '"cmd_$cmd" "$@"'
pass "baseline: grouped stack exec and allowlisted top-level dispatch remain wired"

printf 'Execution contract complete.\n'
