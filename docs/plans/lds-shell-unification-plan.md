# LDS Unified Shell Command Plan

Status: **active — Batches 0–4 implemented; CI validation pending before compatibility consolidation**

## Objective

Introduce `lds shell` as the single human-facing execution/navigation entry point for LocalDevStack while keeping `lib/container-exec.sh` as the shared execution substrate.

The command must reduce the need to choose between `core`, `cli`, `stack exec`, `exec`, and the execution-oriented parts of `tools`.

## Canonical command surface

```text
lds shell
lds shell <target>
lds shell <target> -- <command> [args...]
lds shell <target> --shell <shell-expression>
lds shell <target> --interactive <command> [args...]
```

No-argument `lds shell` is the only form that opens the grouped selector.

## No-argument selector

`lds shell` with no parameters builds one numbered catalog grouped by category:

1. Applications / Domains
2. Application Directories
3. Services
4. Containers
5. Utilities

The selector accepts either:

- the global numeric item number; or
- an exact item name.

When a name occurs in more than one category, the selector must not guess. It reports the ambiguity and accepts a qualified selector such as:

```text
domain:project.localhost
app:project
service:php84
container:localdevstack-php84-1
tools
```

The catalog must be stable/sorted inside each group.

With no TTY, `lds shell` prints the grouped catalog and exits with actionable usage instead of blocking for input.

## Explicit target resolution

For `lds shell <target>`, unqualified targets resolve in this exact order:

```text
1. exact discovered domain
2. reserved LDS target: tools
3. exact current-project Compose service
4. exact Docker container name/ID
5. exact direct child directory /app/<target> inside server-tools
6. target-not-found
```

No fuzzy matching.
No implicit case conversion.
No hostname-shape guessing.
A value is a domain only when Tools reports it as a discovered domain.

Qualified targets bypass precedence and resolve only within their requested category.

## Application-directory fallback

The `app:<name>` / final unqualified fallback is owned by the current project's `server-tools` container.

```text
lds shell billing
  -> no domain
  -> no service
  -> no container
  -> server-tools:/app/billing exists
  -> shell in server-tools with cwd=/app/billing
```

Only direct children of `/app` are eligible. Path traversal and slash-containing fallback names are not accepted.

Do not scan every container for a matching directory.

## Image boundary

Image names are intentionally **not** implicitly instantiated.

`lds shell php:8.4-alpine` must not silently perform `docker run`.

Image execution remains owned by `lds run` unless a future explicit `lds shell --image ...` contract is designed.

## Execution behavior

Resolved targets produce one normalized shell context:

```text
kind
requested
domain
application
service
container_id
container_name
workdir
```

Execution then delegates to the existing substrate.

- no command -> `_container_open_shell`
- `-- <command> ...` -> `_container_exec_argv`
- `--shell <expr>` -> explicit `sh -lc "$expr"`
- `--interactive <command> ...` -> `_container_exec_interactive_argv`

Normal argv execution must never be flattened through a shell.

## TTY and exit-code contract

Preserve the current hardened behavior:

- interactive shell/TUI requires real stdin and stdout TTY;
- piped command keeps stdin without forcing TTY;
- ordinary automation receives no unnecessary TTY flags;
- stopped/missing/ambiguous target errors take precedence over TTY errors;
- child exit status and Ctrl-C style exit 130 propagate unchanged.

Expected LDS control-plane exits:

```text
64 invalid usage / interactive mode without TTY
65 ambiguous target
66 target not found
69 target exists but is unavailable/stopped
```

## Compatibility strategy

During migration:

- `lds core`
- `lds cli`
- `lds stack exec`
- `lds exec`
- `lds tools sh`
- `lds tools exec`
- `lds tools shell-exec`

remain compatible while `lds shell` becomes canonical.

Old commands must not retain independent Docker execution implementations after migration. They should delegate to shared resolution/execution paths while preserving any intentionally narrower legacy contract, especially service-only `stack exec`.

`lds tools file` remains under `tools`; it is inspection functionality, not generic shell navigation.

## Batch tracker

### Batch 0 — Contract and active-plan setup

- [x] define canonical `lds shell` syntax;
- [x] define no-argument grouped selector;
- [x] define number/name/qualified selectors;
- [x] define deterministic explicit-target precedence;
- [x] define `/app/<name>` ownership and traversal boundary;
- [x] keep image instantiation out of implicit shell resolution;
- [x] preserve TTY/argv/exit contracts;
- [x] restore an active plan contract under `docs/plans`.

### Batch 1 — Unified shell context and resolver

- [x] introduce normalized shell context state;
- [x] resolve exact discovered domains;
- [x] resolve reserved `tools`;
- [x] resolve exact current-project services;
- [x] resolve exact containers without emitting premature not-found errors;
- [x] resolve direct `server-tools:/app/<name>` directories;
- [x] support qualified `domain:`, `app:`, `service:`, and `container:` targets;
- [x] add resolver regression coverage.

### Batch 2 — Grouped interactive selector

- [x] build stable grouped catalog;
- [x] include discovered domains;
- [x] include direct `/app` directories;
- [x] include current-project services;
- [x] include running Docker containers;
- [x] include `tools` utility;
- [x] accept global number selector;
- [x] accept exact name selector;
- [x] detect duplicate names and require qualification;
- [x] print catalog + actionable failure without TTY;
- [x] add selector regression coverage.

### Batch 3 — `cmd_shell` execution modes

- [x] no command opens shell in resolved context;
- [x] `--` executes exact argv;
- [x] `--shell` explicitly executes one shell expression;
- [x] `--interactive` executes argv through the interactive helper;
- [x] preserve domain/app workdir;
- [x] add stdin/TTY/exit propagation coverage.

### Batch 4 — Public routing and help

- [x] make `shell` a first-class public LDS command;
- [x] update embedded help;
- [x] update README;
- [x] update CLI reference;
- [x] update documentation contracts.

### Batch 5 — Compatibility consolidation

- [ ] route `core` through unified context behavior where contracts match;
- [ ] route `cli` through unified context behavior where contracts match;
- [ ] preserve service-only `stack exec` compatibility;
- [ ] map `tools sh/exec/shell-exec` to the same execution primitives;
- [ ] ensure no duplicate generic execution implementation remains;
- [ ] decide deprecation-warning policy without breaking automation.

### Batch 6 — Cross-platform and ambiguity hardening

- [ ] Linux/WSL behavior;
- [ ] Git Bash/MSYS path conversion;
- [ ] mixed-case exact containers;
- [ ] domain-like container names;
- [ ] service/domain/app name collisions;
- [ ] stopped/missing/ambiguous target precedence;
- [ ] shell/TUI non-TTY rejection;
- [ ] Ctrl-C / child exit propagation.

### Batch 7 — Full regression and release cleanup

- [ ] ShellCheck/static;
- [ ] CLI/execution/container substrate contracts;
- [ ] environment/catalog/runtime contracts;
- [ ] networking/wrapper/service/QoL/permissions contracts;
- [ ] Windows bridge;
- [ ] Compose;
- [ ] Graphify minimum/latest;
- [ ] common LLM contract;
- [ ] published image baseline;
- [ ] final full CLI surface review;
- [ ] remove this plan only when every item is complete.

## Completion definition

The work is complete when users can rely on:

```text
lds shell
```

as the single discoverable execution/navigation entry point for domains, application directories, services, containers, and Tools, while all legacy execution commands remain either compatibility wrappers or intentionally narrow aliases over the same hardened substrate.

The final architecture must remain:

```text
lds shell
   |
   +-- grouped selector (no args)
   |
   +-- deterministic resolver
          |
          +-- domain
          +-- tools
          +-- service
          +-- container
          +-- /app directory
                 |
                 v
        normalized shell context
                 |
                 v
        lib/container-exec.sh
```
