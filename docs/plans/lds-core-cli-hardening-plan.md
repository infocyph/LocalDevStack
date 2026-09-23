# LocalDevStack — Core & CLI Execution Surface Hardening Plan

## Status

Planning branch: `lds-core-cli/hardening`

Repository: `infocyph/LocalDevStack`

Status: **active plan — synchronized with `main`; implementation not started**

This file is the single active LocalDevStack development plan after completion of the
Docker ecosystem/integration program. The previous `docs/plans/docker-ecosystem/*`
plans are complete and intentionally removed.

## Objective

Make `lds core`, `lds cli`, `lds stack exec`, and `lds tools` feel like one coherent
execution system rather than four independently evolved Docker-shell paths.

The final design should preserve the convenience of the existing commands while
eliminating:

- duplicated container-running checks;
- duplicated Bash/sh fallback logic;
- forced TTY allocation for non-interactive commands;
- command flattening through `$*`;
- raw container-name assumptions;
- implicit uppercasing of container targets;
- domain/container/service ambiguity;
- behavior drift between `core`, `cli`, `stack exec`, and `tools exec`.

The host CLI remains the control plane. Docker remains an implementation detail.

---

# 1. Current behavior

## 1.1 `lds cli`

Current contract:

```text
lds cli <container>
lds cli <container> <command...>
```

Today it:

1. requires an exact Docker container identifier/name;
2. checks that the container exists and is running;
3. always invokes `docker exec -it`;
4. joins command arguments with `$*`;
5. runs explicit commands through a login Bash shell when Bash exists;
6. falls back to `sh` otherwise.

This works interactively, but the command path is not argv-safe and is awkward for
piped/non-TTY automation.

## 1.2 `lds core`

Current contract:

```text
lds core
lds core <domain>
lds core <container>
```

Today it:

- discovers domains through `domain-which`;
- prompts interactively when no target is supplied;
- resolves a domain to application/container/docroot;
- forces Node applications to `/app`;
- otherwise uses the resolved document root with `/app`/root fallback;
- treats a non-domain target as a container name;
- uppercases raw container targets before `docker exec`;
- opens a shell only; it does not have a proper argv-preserving command mode.

## 1.3 Overlapping execution surfaces

The repository also has:

```text
lds stack exec <service> [cmd...]
lds exec <service> [cmd...]
lds tools sh
lds tools exec "<cmd>"
```

Each path currently owns part of the same problem:

- resolve a target;
- require a running container;
- determine interactive vs non-interactive execution;
- choose Bash or sh;
- optionally select a working directory;
- preserve command arguments;
- choose Docker/Compose execution semantics.

That shared substrate should exist once.

---

# 2. Design decisions

## 2.1 Command roles

### `lds cli` — generic container/service execution

`cli` is the low-level execution surface.

Target contract:

```text
lds cli <target>
lds cli <target> -- <command> [args...]
lds cli <target> <command> [args...]
```

A target may be:

1. a service in the current Compose project;
2. an exact running container name/ID.

Resolution must be deterministic and scoped to the current LocalDevStack project before
falling back to an explicit Docker container.

No implicit case conversion.

When no command is supplied, open an interactive shell.

When a command is supplied, preserve argv exactly. Do not flatten the command through
`$*`.

### `lds core` — application/domain-aware execution

`core` remains the ergonomic application entry point.

Target contract:

```text
lds core
lds core <domain>
lds core <domain> -- <command> [args...]
lds core <service|container>
lds core <service|container> -- <command> [args...]
```

Rules:

- no target: discover domains and prompt when interactive;
- one discovered domain: select it automatically;
- non-TTY with multiple domains: print the stable domain list and fail with actionable usage;
- domain target: resolve application/container/docroot through Tools;
- Node target: working directory `/app`;
- other domain target: resolved docroot, then `/app`, then `/` fallback;
- service/container target: use the same resolver as `lds cli`;
- explicit command: execute in the resolved application working directory;
- no command: open the application shell there.

`core` must delegate execution rather than owning Docker shell mechanics itself.

## 2.2 Preserve `stack exec`

`lds stack exec` remains the clearly Compose-service-oriented form.

It should use the same internal argv/TTY/shell helpers as `cli`, while keeping its
service-only contract.

## 2.3 Preserve `tools`

`lds tools` remains server-tools-specific:

```text
lds tools sh
lds tools exec ...
lds tools file ...
```

It should reuse the common container execution layer where applicable instead of carrying
another independent shell implementation.

## 2.4 TTY rules

TTY behavior must be based on the actual operation:

- interactive shell: `-it`;
- interactive explicit command with terminal stdin/stdout: `-it` where appropriate;
- piped/non-interactive command: `-i`, never force `-t`;
- command that needs neither stdin nor TTY: no unnecessary TTY requirement.

Windows/Git Bash, WSL, Linux and Docker Desktop behavior must remain covered.

## 2.5 Command safety

Explicit command execution must be argv-preserving.

Avoid:

```bash
local cmd="$*"
sh -lc "$cmd"
```

for ordinary command forwarding.

If a shell-expression mode is retained for compatibility, it must be explicit and
separate from normal argv execution.

---

# 3. Internal execution architecture

Introduce one private execution substrate in the host CLI layer.

Provisional responsibilities:

```text
_container_resolve_target
_container_require_running
_container_exec_flags
_container_exec_argv
_container_open_shell
_container_exec_in_dir
_core_domain_list
_core_domain_resolve
```

Exact names may change during implementation; responsibilities should not.

## 3.1 Target resolver

The common resolver should return canonical information rather than only a string.

Conceptually:

```text
requested target
      ↓
current Compose service?
      ↓ no
exact Docker container?
      ↓
canonical container id/name
```

Requirements:

- prefer current-project Compose service resolution;
- do not accidentally select a similarly named container from another project;
- exact explicit container names/IDs remain supported;
- return useful errors for stopped/missing/ambiguous targets.

## 3.2 Shell resolver

Interactive shell behavior:

1. Bash when available;
2. sh otherwise.

The helper should support an optional working directory without embedding untrusted
paths into a command string.

## 3.3 Domain resolver

`core` should own domain semantics, not Docker mechanics.

The resolver should return:

```text
domain
application type
container target
working directory
```

The current repeated `domain-which` calls should be wrapped behind one LocalDevStack
helper so failure handling and diagnostics are centralized.

Do not move domain ownership out of Tools; LocalDevStack only consumes the control-plane
result.

---

# 4. Current findings to address

| Area | Current issue | Target |
| --- | --- | --- |
| `cli` target | exact raw container only | Compose service + exact container |
| `cli` command | `$*` flattened into shell string | preserve argv |
| `cli` TTY | always `-it` | adaptive TTY |
| `core` raw target | uppercases container name | canonical resolver |
| `core` command mode | shell only | shell or command |
| `core` domain checks | repeated Tools/container checks | shared domain resolver |
| `stack exec` | separate execution mechanics | shared substrate |
| `tools exec` | separate shell-string mechanics | shared substrate |
| shell fallback | repeated Bash/sh snippets | one helper |
| errors | command-specific wording/behavior | consistent target diagnostics |
| tests | surfaces tested indirectly | explicit execution matrix |
| docs/help | terse semantics | clearly distinguish cli/core/stack exec/tools |

---

# 5. Compatibility policy

Preserve these existing forms:

```text
lds cli <container>
lds cli <container> <command...>
lds core
lds core <domain>
lds core <container>
lds stack exec <service> [command...]
lds exec <service> [command...]
lds tools sh
lds tools exec ...
```

Behavior may become stricter only where the current behavior is unsafe or ambiguous.

Specifically:

- stop uppercasing arbitrary `core` targets;
- stop forcing TTYs for non-interactive commands;
- stop flattening normal command argv;
- reject ambiguous targets rather than guessing.

No dependency on project programming language should be introduced.

---

# 6. Implementation batches

## Batch 0 — baseline and command contract

Status: **complete**

- [x] inventory `core`, `cli`, `stack exec`, `tools`, and top-level dispatch;
- [x] identify duplicated execution responsibilities;
- [x] identify argv/TTY/container-resolution gaps;
- [x] define command roles and compatibility policy;
- [x] add explicit baseline tests for current supported invocation forms before refactor.

Exit criterion: current supported behavior is captured by tests.

## Batch 1 — shared container execution substrate

- [ ] implement current-project service/container resolution;
- [ ] implement running-container validation;
- [ ] implement adaptive `docker exec` flags;
- [ ] implement argv-preserving execution;
- [ ] implement Bash/sh interactive shell selection;
- [ ] implement optional working-directory execution;
- [ ] add unit/contract fixtures for resolver and TTY behavior.

Exit criterion: no user-facing command needs its own Docker shell mechanics.

## Batch 2 — harden `lds cli`

- [ ] move `cmd_cli` onto the shared execution substrate;
- [ ] support current-project Compose service names;
- [ ] preserve explicit container names/IDs;
- [ ] remove forced uppercase/case assumptions;
- [ ] preserve argv exactly for explicit commands;
- [ ] support piped/non-TTY commands without `-t`;
- [ ] keep no-command interactive shell behavior;
- [ ] add missing/stopped/ambiguous target tests.

Exit criterion: `cli` is the reliable low-level execution command.

## Batch 3 — harden `lds core`

- [ ] centralize domain discovery;
- [ ] centralize domain -> app/container/docroot resolution;
- [ ] preserve stable interactive domain picker;
- [ ] preserve useful non-TTY domain listing;
- [ ] delegate service/container fallback to the common resolver;
- [ ] remove raw target uppercasing;
- [ ] add explicit command execution after domain/container target;
- [ ] preserve Node `/app` behavior;
- [ ] preserve document-root fallback behavior;
- [ ] test PHP, Node, service, container and non-TTY flows.

Exit criterion: `core` is application-aware but contains no duplicate Docker execution logic.

## Batch 4 — unify adjacent execution surfaces

- [ ] move `cmd_exec` / `stack exec` onto shared helpers without changing its service-only UX;
- [ ] move `tools sh` onto shared shell helper;
- [ ] move `tools exec` away from unsafe command flattening where compatibility allows;
- [ ] review `cmd_ui`/other direct `docker exec` users for helper reuse where relevant;
- [ ] keep specialized commands specialized; do not over-abstract unrelated Docker operations.

Exit criterion: interactive/command execution semantics are consistent across LDS.

## Batch 5 — CLI routing and UX cleanup

- [ ] review top-level dynamic `cmd_$cmd` routing for discoverability and collision safety;
- [ ] ensure canonical grouped commands and shortcuts remain intentional;
- [ ] standardize usage/error text;
- [ ] standardize exit codes for missing target, unknown target, stopped target and no-TTY prompt;
- [ ] make `--` command separation work consistently;
- [ ] ensure help output clearly explains `core` vs `cli` vs `stack exec` vs `tools`.

Exit criterion: users can predict which execution command to use without knowing LDS internals.

## Batch 6 — cross-platform and automation hardening

- [ ] Linux interactive shell coverage;
- [ ] Linux piped stdin/non-TTY coverage;
- [ ] Windows/Git Bash TTY compatibility;
- [ ] WSL behavior review;
- [ ] Docker Desktop behavior review;
- [ ] paths containing spaces;
- [ ] commands containing spaces/quotes/shell metacharacters as argv;
- [ ] SIGINT/exit-code propagation;
- [ ] no accidental host shell interpolation.

Exit criterion: execution behavior is stable across supported host environments.

## Batch 7 — documentation and release hardening

- [ ] update `docs/reference/cli.rst`;
- [ ] update embedded `lds help` / `help --markdown`;
- [ ] update README examples only where useful;
- [ ] update docs contracts;
- [ ] run ShellCheck/static/contracts;
- [ ] run Compose/network/permission contracts;
- [ ] run Windows bridge contract;
- [ ] final full CLI surface review;
- [ ] remove this plan when every item is complete.

Exit criterion: all checks green and no completed planning artifact remains.

---

# 7. Required regression matrix

At minimum cover:

| Command | Interactive | Non-interactive | Domain | Service | Container |
| --- | --- | --- | --- | --- | --- |
| `lds cli` | yes | yes | n/a | yes | yes |
| `lds core` | yes | yes | yes | yes | yes |
| `lds stack exec` | yes | yes | n/a | yes | n/a |
| `lds tools` | yes | yes | n/a | server-tools | server-tools |

Also verify:

- stopped target;
- missing target;
- ambiguous service/container naming;
- one-domain auto-selection;
- multi-domain no-TTY output;
- PHP domain working directory;
- Node domain `/app`;
- Bash unavailable -> sh;
- stdin pipe reaches child command;
- child exit status reaches caller;
- `Ctrl-C` reaches interactive child;
- command arguments are not reinterpreted by the host shell.

---

# 8. Non-goals

Do not use this work to:

- redesign Compose service definitions;
- move domain ownership out of docker-tools;
- introduce a new programming-language/runtime dependency;
- replace Docker Compose;
- merge unrelated service lifecycle commands;
- remove existing command aliases merely for aesthetic cleanup;
- turn every direct Docker call into a generic abstraction.

The goal is a coherent execution surface, not abstraction for its own sake.

---

# 9. Completion definition

This plan is complete when:

1. `lds cli` is the dependable low-level service/container execution surface;
2. `lds core` is the dependable application/domain execution surface;
3. both support correct interactive and non-interactive behavior;
4. argv, stdin, TTY, exit codes and working directories are preserved correctly;
5. `stack exec` and `tools` reuse the same execution substrate where appropriate;
6. current-project scoping prevents accidental cross-project container selection;
7. help/docs make the command boundaries obvious;
8. Linux/Windows/WSL contracts are green;
9. no completed predecessor plan files remain;
10. this plan itself is removed after implementation is fully released.
