# Shared Foundations Plan — Scriptomatic + Toolset

## Purpose

Define the Scriptomatic/Toolset dependency contract LocalDevStack should consume without redesigning the behavior of either upstream repository.

## Accepted upstream contracts

### Scriptomatic

- canonical source: `main`
- optional reproducible pin: `SCRIPTOMATIC_REF=<commit-sha>`
- no Scriptomatic tag/release lifecycle
- PHP/Node bootstrap keeps the existing public inputs and developer-container behavior from Scriptomatic `main`

### Toolset

- stable dependency: `TOOLSET_REF=2.0`
- use release assets/checksums rather than Toolset `main`/`master`

## Current LocalDevStack migration

The current PHP and Node Dockerfiles still bootstrap from:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/master/...
```

During the LocalDevStack implementation phase, replace that hard-coded `master` source with an explicit Scriptomatic ref:

```dockerfile
ARG SCRIPTOMATIC_REF=main
ARG TOOLSET_REF=2.0
```

Fetch `php-cli-setup.sh` / `node-cli-setup.sh` from the selected Scriptomatic ref and pass `SCRIPTOMATIC_REF` plus `TOOLSET_REF` into the setup process so sibling helpers use the same Scriptomatic ref and Toolset helpers use stable `2.0`.

For a reproducible build, LocalDevStack may set `SCRIPTOMATIC_REF` to the accepted Scriptomatic commit SHA.

## Preserve the existing Docker build inputs

Do not rename the existing PHP/Node identity inputs. The setup scripts continue to consume the Docker build environment:

```text
UID
GID
```

along with the existing package/runtime inputs.

PHP:

```text
LINUX_PKG
LINUX_PKG_VERSIONED
PHP_EXT
PHP_EXT_VERSIONED
MSMTP_FROM
```

Node:

```text
LINUX_PKG
LINUX_PKG_VERSIONED
NODE_GLOBAL
NODE_GLOBAL_VERSIONED
NODE_LOG_DIR
```

Do not introduce `SCRIPTOMATIC_UID`, `SCRIPTOMATIC_GID`, Composer-version, PHP-extension-installer-version, npm-version, reproducibility-mode, sudo-mode or Oh-My-Bash-mode inputs merely for the shared-foundations migration.

## PHP behavior LocalDevStack should expect

Scriptomatic preserves the existing PHP development-image behavior:

- Alpine official PHP/FPM conventions;
- Composer installed through `install-php-extensions @composer`;
- requested PHP extensions;
- passwordless sudo for the developer user;
- Oh My Bash with the existing `lambda` theme/plugin set;
- PHP/FPM, msmtp, Composer home, banner and aliases;
- non-root runtime through `php-entry`.

Hardening is underneath that behavior: safer argv handling, bounded/private downloads, same-ref Scriptomatic helpers, Toolset `2.0` checksum verification, root-owned shared executables, idempotent config and content-aware root-CA refresh.

## Node behavior LocalDevStack should expect

Scriptomatic preserves the existing Node development-image behavior:

- upstream UID-1000 user reuse/rename when applicable;
- passwordless sudo;
- Oh My Bash and aliases;
- user npm cache/global prefix;
- build-time `npm install -g npm@latest || npm install -g npm@next || true`;
- optional global package inputs;
- non-root runtime through `node-entry`.

The Node entrypoint keeps its existing logging, automatic dependency installation/fallback, `NODE_CMD`, host/port and keepalive behavior. Hardening only fixes stale CA-state handling and the generic-dev double-execution bug.

## Root CA

The existing entrypoint input remains:

```text
ROOTCA_PATH
```

System CA installation remains best-effort at the existing fixed destination. No new strictness/destination policy inputs are required from LocalDevStack.

## Shared utilities

- `alias-maker.sh`: keep the aliases/functions from Scriptomatic `main`.
- `banner.sh`: keep the centered INFOCYPH presentation, three-row description box, rotating credits and ChromaCat styles; fallback only when presentation capabilities are unavailable.
- `docknotify.sh`: keep `SERVER_TOOLS:9901`/best-effort behavior; protocol framing is corrected underneath.
- `owners.sh`: keep its original human output shape while using safe Git filename enumeration.

## Certbot

`certbot-hook.sh` keeps fixed `NGINX` / `APACHE` targets and reload-if-running behavior. Exact inspection and non-TTY exec are implementation fixes.

`certbot-renew.sh` remains the existing infinite 12-hour renewal loop. LocalDevStack should not pass interval/jitter/failure-threshold configuration that Scriptomatic does not expose.

## Mongo

`mongo-replica.sh` retains its fixed topology:

```text
rs0
mongo-primary:27017
mongo-secondary1:27017
mongo-secondary2:27017
```

The hardening is readiness/idempotency/conflict handling only. No new Mongo topology environment contract is required from LocalDevStack.

## LocalDevStack implementation acceptance criteria

1. No PHP/Node Dockerfile downloads Scriptomatic from `master`.
2. No LocalDevStack consumer downloads Toolset helpers from a mutable branch.
3. PHP/Node Dockerfiles expose `SCRIPTOMATIC_REF` and `TOOLSET_REF` while preserving existing `UID`, `GID` and package/runtime inputs.
4. PHP and Node developer-image behavior remains unchanged from the existing LocalDevStack experience.
5. PHP/Node runtime remains non-root and their entrypoints preserve the existing command semantics.
6. `docknotify` still interoperates with the LocalDevStack notification service.
7. Service-to-service names continue to use Docker DNS rather than static IP addresses.
8. Consumer CI builds representative PHP and Node images against the accepted Scriptomatic ref and Toolset `2.0`.
