# Shared Foundations Plan — Scriptomatic + Toolset

## Purpose

Stabilize the two shared repositories consumed by LocalDevStack Docker images before changing the image layer itself.

This is a dependency-contract plan, not a wholesale redesign of Scriptomatic or Toolset.

## Repositories

- `infocyph/Scriptomatic`
- `infocyph/Toolset`

## Primary Problems to Solve

1. Docker builds currently fetch helpers from mutable `main`/`master` URLs.
2. A rebuild of unchanged Docker source can therefore silently receive different helper code.
3. Shell/bootstrap behavior is consumed by several images without a shared compatibility contract.
4. Some helper scripts are large enough that syntax-only confidence is insufficient.

## Contract to Establish

Every downstream image must be able to select immutable revisions through explicit build arguments, for example:

- `SCRIPTOMATIC_REF=<release-or-commit>`
- `TOOLSET_REF=<release-or-commit>`

Preferred source format:

`https://raw.githubusercontent.com/infocyph/<repo>/<immutable-ref>/<path>`

If release tags are used, treat released helper content as immutable. If the repos do not yet maintain releases consistently, use commit SHAs until that lifecycle exists.

## Scriptomatic — File-by-File Plan

### `.github/`

Create validation workflow(s) for shell scripts.

Required checks:

- `bash -n bash/*.sh` where Bash is required;
- `sh -n` only for scripts explicitly POSIX-shell compatible;
- ShellCheck with documented intentional suppressions only;
- smoke tests for PHP and Node setup scripts using disposable containers where practical.

Do not add a release/publish workflow unless Scriptomatic is intentionally moved to a release-tag lifecycle.

### `bash/php-cli-setup.sh`

Current role: builds LocalDevStack PHP developer-runtime behavior.

Plan:

- preserve PHP extension/package customization inputs;
- preserve UID/GID user creation, Composer home isolation, FPM setup, Mailpit/msmtp, Git configuration and shell helpers;
- replace floating Toolset/Scriptomatic helper URLs with ref-driven URLs supplied through environment/build context;
- fail clearly when a required helper cannot be fetched;
- avoid `latest`-style helper installers where an immutable version/checksum can be selected;
- validate generated PHP/FPM configuration in smoke CI;
- ensure cleanup does not remove runtime-required assets;
- document inputs used by LocalDevStack Dockerfile (`PHP_EXT`, `PHP_EXT_VERSIONED`, `LINUX_PKG`, `LINUX_PKG_VERSIONED`, UID/GID, profile key).

### `bash/node-cli-setup.sh`

Current role: builds LocalDevStack Node developer-runtime behavior.

Plan:

- preserve UID/GID reuse/rename behavior for the upstream `node` user;
- preserve npm cache/global prefix and Corepack behavior;
- make Toolset/Scriptomatic helper downloads immutable/ref-driven;
- review whether unconditional `npm@latest` upgrade is desirable for reproducible runtime images; prefer explicit npm policy/version input if retained;
- validate generated user/home/global-package permissions;
- smoke-test a generated Node runtime as non-root.

### `bash/php-entry.sh`

Plan:

- syntax check;
- validate signal/exec semantics;
- ensure mounted CA/config initialization remains idempotent;
- keep entrypoint small; do not move build-time setup into runtime.

### `bash/node-entry.sh`

Plan:

- syntax check;
- validate command forwarding and signal semantics;
- ensure runtime setup is idempotent;
- keep project command execution as the final `exec` path.

### `bash/banner.sh`

Plan:

- treat as shared presentation helper only;
- syntax/ShellCheck validation;
- no runtime-critical logic should depend on banner rendering succeeding;
- downstream images should pin its revision rather than fetch `master`.

### `bash/alias-maker.sh`

Plan:

- validate idempotency;
- ensure aliases do not hide core commands in non-interactive execution;
- document which aliases are relied on by LocalDevStack developer shells.

### `bash/docknotify.sh`

Plan:

- validate behavior when notification transport is unavailable;
- never make normal PHP/Node process startup depend on desktop notification success;
- add minimal smoke coverage for no-listener behavior.

### `bash/owners.sh`

Plan:

- confirm whether current LocalDevStack images still consume it;
- if unused by all current Dockerfiles, mark as standalone Scriptomatic utility rather than part of the LocalDevStack compatibility contract.

### `bash/mongo-replica.sh`

Plan:

- determine whether LocalDevStack currently calls it;
- if retained for future Mongo replica support, add syntax validation and document expected container/network assumptions;
- do not introduce replica-set complexity into default LocalDevStack profiles as part of this program.

### `bash/certbot-hook.sh` / `bash/certbot-renew.sh`

Plan:

- explicitly classify as production/server helpers, not LocalDevStack local-TLS dependencies;
- leave out of LocalDevStack compatibility gating unless direct usage is found.

### `bash/alias-maker.sh`, `banner.sh`, `docknotify.sh`, `php-entry.sh`, `node-entry.sh`

Add a compact compatibility test matrix because these are directly pulled into runtime images.

## Toolset — File-by-File Plan

Only utilities directly consumed by the Docker ecosystem are in the critical path.

### `Git/gitx`

Current consumers: `docker-tools`, PHP runtime setup, Node runtime setup.

Plan:

- establish an immutable ref used by images;
- run Bash syntax/ShellCheck if compatible with its implementation style;
- add smoke tests for non-destructive commands needed inside dev containers;
- do not couple `gitx` to `llm-sm`; AI commit behavior already lives independently in `docker-llm-sm`.

### `ChromaCat/chromacat`

Current consumers: tools/runner/nginx/apache/PHP/Node developer shells.

Plan:

- pin downstream consumption;
- validate no-color/non-TTY behavior;
- make banner/color failures non-critical;
- keep it purely presentational.

### `Sqlite/sqlitex`

Current consumer: `docker-tools`.

Plan:

- pin downstream consumption;
- smoke-test basic database open/query behavior against temporary SQLite data;
- document runtime package dependency expectations.

### `Network/netx`

Current consumer: `docker-tools`.

Plan:

- pin downstream consumption;
- smoke-test basic local network inspection without requiring privileged host operations;
- ensure failures are diagnostic rather than destructive.

### `Docker/dockex`

Plan:

- inspect whether LocalDevStack or `docker-tools` currently installs/calls it;
- if unused, do not add it merely for symmetry;
- if later adopted, treat Docker-socket permission requirements explicitly.

### `PHP/phpx`

Plan:

- inspect whether current PHP wrappers already provide the required behavior;
- do not introduce it into LocalDevStack runtime images unless it replaces duplicated functionality with a clear compatibility win.

### `Clean/cleanx`

Plan:

- keep out of default container images unless a concrete LocalDevStack command adopts it;
- destructive cleanup remains explicit and host-controlled.

### Toolset docs/README files

Update only when dependency/release guarantees change. Do not rewrite unrelated documentation during Docker ecosystem work.

## New Shared Validation Artifacts

If missing, add lightweight test directories/workflows in Scriptomatic and Toolset rather than embedding compatibility tests into downstream Dockerfiles.

Suggested test categories:

- syntax;
- non-interactive execution;
- no-color mode;
- temporary HOME/user paths;
- read-only Git/config mounts;
- expected failure behavior when optional host integrations are absent.

## Downstream Consumption Pattern

Each downstream Dockerfile should stop hard-coding:

- `Toolset/main/...`
- `Scriptomatic/master/...`

and move to explicit build args/defaults tied to accepted immutable revisions.

Do not duplicate Scriptomatic/Toolset source into every Docker repo unless GitHub availability at build time becomes an unacceptable dependency and a vendoring decision is made intentionally.

## Acceptance Criteria

1. Required Scriptomatic scripts pass syntax + ShellCheck policy.
2. PHP and Node setup smoke tests pass in disposable upstream base containers.
3. Toolset utilities used by the Docker ecosystem have smoke validation.
4. Every downstream image can point to immutable Scriptomatic/Toolset refs.
5. Rebuilding the same Docker release source with the same base image/ref inputs does not silently receive newer helper scripts.
6. Optional presentation/notification helpers cannot prevent the primary container service from starting.
