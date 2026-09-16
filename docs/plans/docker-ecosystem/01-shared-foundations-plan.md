# Shared Foundations Plan — Scriptomatic + Toolset

## Purpose

Stabilize the shared Scriptomatic/Toolset dependency contract consumed by LocalDevStack Docker images before changing the image layer itself.

This remains a dependency-contract plan. Scriptomatic owns reusable bootstrap/runtime behavior; Toolset owns released CLI utilities; LocalDevStack owns image composition/orchestration.

## Repositories and accepted upstream contracts

- `infocyph/Scriptomatic`
  - canonical source: `main`
  - reproducible consumers: `SCRIPTOMATIC_REF=<commit-sha>`
  - no Scriptomatic tag/release lifecycle required
  - all sibling Scriptomatic helpers use the same selected ref
- `infocyph/Toolset`
  - stable Docker-ecosystem dependency: `TOOLSET_REF=2.0`
  - released executables/checksum contract; do not consume Toolset `main`/`master`

## Current LocalDevStack mismatch to remove

The current PHP and Node Dockerfiles still contain:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/master/...
```

This must be removed during the LocalDevStack implementation phase.

Do not replace it with another hard-coded mutable URL. Add explicit build arguments and propagate the same selected ref into the bootstrap script.

Required downstream inputs:

```text
SCRIPTOMATIC_REF=main
SCRIPTOMATIC_BASE_URL=https://raw.githubusercontent.com/infocyph/Scriptomatic
TOOLSET_REF=2.0
SCRIPTOMATIC_UID=<configured uid>
SCRIPTOMATIC_GID=<configured gid>
```

For immutable/reproducible image builds, `SCRIPTOMATIC_REF` must be the accepted Scriptomatic commit SHA rather than `main`.

## Initial Scriptomatic bootstrap acquisition

The Dockerfile must acquire the initial `php-cli-setup.sh` / `node-cli-setup.sh` through the selected ref with bounded download behavior. Do not use remote `ADD` against `master`.

Recommended shape:

```dockerfile
ARG SCRIPTOMATIC_REF=main
ARG SCRIPTOMATIC_BASE_URL=https://raw.githubusercontent.com/infocyph/Scriptomatic
ARG TOOLSET_REF=2.0

RUN apk add --no-cache bash curl ca-certificates && \
    curl --fail --location --silent --show-error \
      --connect-timeout 5 --max-time 90 --retry 3 \
      "${SCRIPTOMATIC_BASE_URL}/${SCRIPTOMATIC_REF}/bash/php-cli-setup.sh" \
      -o /usr/local/bin/cli-setup.sh && \
    SCRIPTOMATIC_REF="${SCRIPTOMATIC_REF}" \
    SCRIPTOMATIC_BASE_URL="${SCRIPTOMATIC_BASE_URL}" \
    TOOLSET_REF="${TOOLSET_REF}" \
    SCRIPTOMATIC_UID="${UID}" \
    SCRIPTOMATIC_GID="${GID}" \
    bash /usr/local/bin/cli-setup.sh "${USERNAME}" "${PHP_VERSION}"
```

Use the analogous path for Node.

## Scriptomatic accepted behavior

### PHP build/runtime

`php-cli-setup.sh` now provides:

- validated package/extension inputs;
- Alpine official-PHP-image capability checks;
- pinned/verified PHP extension installer;
- Composer available by default through pinned `COMPOSER_VERSION=2.10.3`, without the old floating self-update;
- Toolset `2.0` helper installation from released/checksummed assets;
- same-ref Scriptomatic helper installation;
- root-owned `/usr/local/bin` helpers;
- generated PHP/FPM validation;
- repeat/idempotent bootstrap coverage;
- preserved trusted-development shell defaults (passwordless sudo and Oh My Bash) with explicit opt-out controls;
- preserved setup progress/banner presentation;
- no broad shared-temp cleanup/self-delete.

`php-entry.sh` provides content-aware mounted-root-CA refresh and transparent `exec docker-php-entrypoint "$@"` semantics.

### Node build/runtime

`node-cli-setup.sh` now provides:

- validated package/global-package inputs;
- verified upstream UID reuse/rename behavior;
- optional exact npm version rather than `npm@latest`/`npm@next`;
- reproducible global-package mode;
- Toolset `2.0` and same-ref Scriptomatic helpers;
- root-owned shared executables;
- preserved trusted-development shell defaults (passwordless sudo and Oh My Bash) with explicit opt-out controls;
- preserved setup progress/banner presentation.

`node-entry.sh` keeps the established LocalDevStack developer-container defaults:

```text
NODE_LOG_ENABLED=1
NODE_KEEPALIVE_ON_FAIL=1
NODE_AUTO_INSTALL=1
NODE_ALLOW_LOCKFILE_FALLBACK=1
```

Each can be set to `0` for stricter/production-like behavior. The entrypoint selects one final command and `exec`s it. Direct argv is preferred; `NODE_CMD` remains a trusted compatibility escape hatch.

## Trusted development sudo / root CA

Scriptomatic keeps the historical trusted-development default:

```text
SCRIPTOMATIC_PASSWORDLESS_SUDO=1
```

LocalDevStack PHP/Node images run as non-root at runtime, and their developer shells historically include passwordless sudo. This also provides the privilege path needed when a mounted root CA must be copied/refreshed during entrypoint startup.

For stricter images that do not need runtime sudo/CA mutation, explicitly set:

```text
SCRIPTOMATIC_PASSWORDLESS_SUDO=0
```

Use `ROOTCA_REQUIRED=1` only where inability to install the mounted CA should make startup fail.

## Shared utility contract

### `alias-maker.sh`

- managed/idempotent `.bashrc` block;
- does not interfere with non-interactive application execution;
- optional aliases degrade cleanly.

### `banner.sh`

- keeps the established INFOCYPH centered presentation, rotating credit pool, ChromaCat box-style pool, and three-row description box;
- presentation-only;
- safe fallback without `figlet`/`chromacat`;
- non-TTY / `NO_COLOR` safe;
- banner failure cannot prevent shell/container startup.

### `docknotify.sh`

LocalDevStack-compatible defaults remain:

```text
NOTIFY_HOST=SERVER_TOOLS
NOTIFY_TCP_PORT=9901
DOCKNOTIFY_STRICT=0
```

Notification is best-effort unless strict mode is explicitly requested. Optional tuning values retain permissive compatibility behavior. The protocol is one tab-separated newline-terminated record and token data is not emitted in diagnostics.

### `owners.sh`

Standalone repository utility; not part of the critical LocalDevStack runtime contract unless adopted explicitly. Its established human-readable output shape is preserved while Git path enumeration is hardened.

## Service-helper contract

### Certbot

`certbot-hook.sh` is Docker-control-plane behavior:

- exact container inspection;
- no TTY;
- configurable Nginx/Apache container names;
- bounded reload;
- missing or stopped optional targets skip, preserving the original reload-if-running behavior;
- an attempted reload failure propagates non-zero.

Do not mount the Docker socket into ordinary PHP/Node application containers just to support this helper.

`certbot-renew.sh` is a signal-aware foreground service loop with interval/jitter/backoff controls. Unlimited retry remains the compatibility default (`CERTBOT_RENEW_MAX_FAILURES=0`); a positive threshold can be configured when repeated failures should terminate the container.

### Mongo replica bootstrap

`mongo-replica.sh`:

- uses bounded readiness rather than fixed sleeps;
- prefers `mongosh` with legacy `mongo` fallback;
- separates connection URI from advertised replica members;
- defaults advertised members to Docker DNS names;
- is idempotent for a matching topology;
- initializes only when uninitialized;
- refuses conflicting existing topology.

Default advertised topology:

```text
mongo-primary:27017
mongo-secondary1:27017
mongo-secondary2:27017
```

Do not replace service names with static `172.x` addresses.

## Shell compatibility boundary

LocalDevStack developer workflows may use `bash`, `sh`, and `sh -l`.

- standalone helpers under `/usr/local/bin` have their own shebangs;
- Bash-specific profile/alias behavior belongs to Bash/login presentation paths;
- non-login `sh` is not required to source Bash-only configuration;
- PHP/Node application entrypoints do not depend on interactive shell startup.

## Toolset accepted dependency contract

The Docker ecosystem consumes Toolset stable `2.0` rather than mutable repository branches.

Critical current utilities remain:

- `gitx`
- `chromacat`
- `sqlitex` where docker-tools requires it
- `netx` where docker-tools requires it

Do not add `dockex`, `phpx`, or `cleanx` to LocalDevStack merely for symmetry; adoption requires a concrete downstream need.

## Permanent upstream validation

Scriptomatic CI now covers:

- syntax + ShellCheck;
- repository-wide security audit;
- PHP Alpine bootstrap + repeated execution;
- Node Alpine bootstrap including UID reuse/fresh-user paths;
- entrypoint exit/signal behavior;
- shared utility fixtures;
- Certbot/Mongo deterministic service-helper fixtures;
- aggregate gate.

Toolset keeps its own permanent release/utility gates.

Do not duplicate these upstream suites inside LocalDevStack. LocalDevStack should add consumer/integration tests that prove its Dockerfiles pass the correct refs/options and that generated images start correctly.

## LocalDevStack implementation acceptance criteria

1. No Dockerfile consumes `Scriptomatic/master` or `Toolset/main`/`master`.
2. PHP/Node image builds expose `SCRIPTOMATIC_REF` and `TOOLSET_REF` build inputs.
3. Reproducible builds can pin Scriptomatic by commit SHA and Toolset by accepted stable release.
4. Explicit `SCRIPTOMATIC_UID`/`SCRIPTOMATIC_GID` are passed into setup.
5. Trusted developer images preserve the established Scriptomatic sudo/Oh My Bash defaults; stricter images may explicitly disable them.
6. PHP/Node images remain non-root at runtime and preserve entrypoint `exec` semantics.
7. `bash`, `sh`, and `sh -l` remain usable for their intended roles.
8. `docknotify` can reach `SERVER_TOOLS:9901` when enabled and remains non-critical when unavailable.
9. service-to-service references use Docker DNS/service names, not static IP assumptions.
10. consumer CI builds representative PHP and Node images using the pinned shared-foundation refs.
