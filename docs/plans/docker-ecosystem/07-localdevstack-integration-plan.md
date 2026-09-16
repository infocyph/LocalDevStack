# LocalDevStack — File-by-File Integration + Product Plan

## Role

`infocyph/LocalDevStack` is the product/orchestrator above all supporting Docker images. It should present a simple XAMPP-like local-development experience while hiding most Docker complexity.

This phase executes only after lower-level image contracts are stable.

## Product Invariants

- `lds` remains the single primary CLI.
- `lds.bat` keeps Windows/Git Bash interoperability.
- PHP and Node remain locally generated/customizable runtimes.
- Nginx remains the default HTTP/TLS edge.
- Apache remains optional.
- databases/admin clients/mail/runner remain selectively enabled through profiles/configuration.
- local TLS and multiple domains remain first-class.
- AI remains optional.
- persisted DB/cache/mail/model data survives container recreation.
- project source remains host-mounted, not copied into infrastructure images.

## Top-Level Files

### New `.github/workflows/check.yml`

Add product-level CI before major refactoring.

Required stages:

1. `bash -n` for `lds` and Bash wrappers;
2. ShellCheck for maintained scripts with explicit suppressions;
3. validate `lds.bat` static expectations where Windows runners are practical;
4. Compose configuration validation with representative profile sets;
5. generated PHP runtime Compose fixture;
6. generated Node runtime Compose fixture;
7. canonical service-catalog schema validation;
8. smoke `lds help`, `lds config`, profile parsing, env handling without destructive host operations;
9. integration job using released supporting images for core Nginx/Tools/Runner flow;
10. optional heavier domain/TLS/runtime smoke job.

Use Linux CI as baseline; add Windows CI for bridge/path-specific behavior rather than trying to run every container integration twice.

### `.gitignore`

Current file is allowlist-oriented.

Plan:

- keep the allowlist model if intentional;
- whitelist new static product resources such as `docker/catalog/**`, tests and CI fixtures;
- keep generated runtime `.env`, certificates, secrets, logs and user-generated Compose artifacts ignored;
- make the tracked-vs-generated boundary explicit.

### `.gitattributes`

Preserve LF shell scripts and Windows batch compatibility. Add path-specific rules only if needed.

### `README.md`

Rewrite after implementation to present the product as a Docker-based XAMPP alternative for PHP + Node.

Quickstart should prioritize:

- install Docker;
- clone/setup `lds`;
- select services/runtime;
- create domain;
- trust local CA;
- work through `lds php`, `lds composer`, Node/npm commands and service shortcuts.

Keep advanced internals in docs, not the first screen.

### `LICENSE`

No change.

## `lds` Modularization

### Existing `lds`

Do not rewrite behavior in one step.

Migration sequence:

1. add characterization tests around current commands;
2. identify stable command/public-output contracts;
3. extract internal modules while leaving `lds` as bootstrap/dispatcher;
4. only then simplify duplicated code.

Target layout:

- `lds` — bootstrap, global flag parsing, command dispatch;
- `lib/core.sh` — errors, output, command/tool lookup, OS detection;
- `lib/compose.sh` — Compose wrapper, service resolution, profiles/extras;
- `lib/env.sh` — dotenv read/write/quoting and product defaults;
- `lib/catalog.sh` — canonical service/runtime catalog reader;
- `lib/profiles.sh` — service/profile selection and persistence;
- `lib/hosts.sh` — mkhost/rmhost integration and reload lifecycle;
- `lib/certificates.sh` — host trust-store install/uninstall;
- `lib/runtime.sh` — PHP/Node/runtime-image generation/rebuild integration;
- `lib/diagnostics.sh` — doctor/diag/sniff/status helpers;
- `lib/maintenance.sh` — clean/disk/events/rebuild operations;
- `lib/platform.sh` — Windows/macOS/Linux path/platform helpers when separation is useful.

Rules:

- sourced modules are not user-facing commands;
- no module should execute work merely when sourced;
- keep `set -euo pipefail` behavior intentional;
- avoid global mutable state where function-local state works;
- preserve existing command aliases until a documented deprecation.

### `lds.bat`

Plan:

- preserve Git-for-Windows Bash bridge;
- preserve caller working directory and Windows->Unix path conversion;
- validate Docker installed/running errors;
- add CI/static smoke for quoting paths containing spaces;
- avoid duplicating `lds` command semantics in batch.

## Canonical Service Catalog

### New `docker/catalog/services.json`

Create one canonical product catalog consumed by `lds` and mounted/read by `docker-tools`.

Initial schema should describe at least:

- service/profile key;
- display name;
- image/version env variable;
- default version/value;
- setup prompt fields/defaults;
- related admin client profile/service where applicable;
- convenience route metadata where useful;
- persistence volume identifier;
- optional health/dependency metadata only when needed by orchestration.

Initial catalog covers:

- PostgreSQL;
- MySQL;
- MariaDB;
- MongoDB;
- Redis;
- Elasticsearch;
- optional AI service metadata in a separate capability section or same versioned schema.

Do not put secrets directly in catalog. Default dev credentials may be expressed as defaults but user values live in env state.

### Remove duplicated profile defaults

After `docker-tools` supports external catalog:

- replace hard-coded `SERVICES`/`PROFILE_ENV` duplication in `lds` with catalog reads;
- mount catalog into `server-tools`;
- remove Tools fallback duplication only after compatibility period/tests.

## `bin/` Wrappers

### `bin/tool-runner`

- keep common container execution/path/TTY logic centralized;
- make it the reusable primitive for thin service wrappers where possible;
- ensure Windows path conversion and UID/GID behavior are tested;
- propagate exit codes and signals.

### `bin/php`

- preserve runtime selection/highest-version fallback;
- keep explicit `--php/-V` selection;
- preserve ad-hoc execution using the selected runtime image;
- validate bind mount and user mapping on Linux/macOS/Windows;
- keep `serve` mode if still useful, but separate it cleanly from normal CLI execution;
- align Git safe-directory behavior for mounted projects.

### `bin/composer`

- reduce duplicated runtime-resolution code by consuming `tool-runner`/shared helper where possible;
- preserve PHP-version selection and versioned Composer home;
- test install/update/global operations against mounted project.

### `bin/my`

- preserve MySQL login/query/export/import helper behavior;
- resolve service by Compose name/labels, not static IP;
- keep credentials from environment;
- validate quoting and database/file paths.

### `bin/maria`

Same principles as `bin/my`, using MariaDB client/service contract.

### `bin/pg`

- preserve PostgreSQL login/query/dump/restore helpers;
- DNS service name only;
- environment-driven credentials;
- test dump/restore with temporary DB.

### `bin/mongo`

- preserve mongosh/login/import/export helpers;
- DNS service name only;
- environment-driven auth;
- no replica-set assumption in default flow.

### `bin/redis-cli`

- preserve thin Redis CLI behavior;
- DNS service name and optional auth env;
- keep wrapper small.

### `bin/es`

- preserve Elasticsearch API/helper behavior;
- use service name rather than fixed IP;
- validate ES 9.x/current compatibility via version-aware requests;
- no hidden Kibana dependency for core ES commands.

## Docker Compose Files

### `docker/compose/main.yaml`

Major network migration:

- keep logical `frontend`, `backend`, `datastore` bridge networks;
- remove hard-coded subnets/gateways after integration validation;
- remove need for fixed container IPv4 values from included files;
- keep named persistent volumes;
- add AI model volume only when AI profile integration lands;
- consider namespacing globally fixed volume/network names if multi-stack coexistence needs it; do not break existing data without migration guidance.

### `docker/compose/companion.yaml`

Services: `server-tools`, `runner`, `mailpit`.

Plan:

- replace static IPv4 declarations with networks/service DNS;
- move infrastructure image references from hard-coded `:latest` to environment-controlled compatibility-tested versions;
- mount canonical service catalog into `server-tools` read-only;
- inventory Docker socket usage for both Tools and Runner;
- preserve project/config/scheduler/SOPS/SSH/SSL/log mounts;
- preserve Mailpit persistent data and local TLS;
- add health/dependency conditions only where they improve deterministic startup without deadlocks.

### `docker/compose/http.yaml`

Services: Nginx + optional Apache.

Plan:

- remove static IPs;
- version image refs through LocalDevStack defaults/env;
- keep Nginx host 80/443 binding configurable;
- preserve project/vhost/cert/rootCA/FPM socket/log mounts;
- preserve Apache as internal backend;
- use service names for dependency/routing;
- reconsider `restart: always` vs consistent `unless-stopped` behavior for local dev.

### `docker/compose/db.yaml`

Services: Redis, PostgreSQL, MySQL, MongoDB, MariaDB, Elasticsearch.

Plan:

- remove all static IPv4 assignments;
- source default version/env metadata from canonical catalog;
- retain named volumes;
- review data-directory mount correctness per current upstream images (especially PostgreSQL version changes);
- retain healthchecks but correct variable-name mismatches (`POSTGRES_DATABASE` vs `POSTGRES_DB`, etc.);
- avoid `latest` defaults for compatibility-sensitive DB majors where a stable major is preferable;
- keep local-development credentials configurable and clearly non-production.

### `docker/compose/db-client.yaml`

Services: RedisInsight, CloudBeaver, Mongo Express, Kibana, Filebeat.

Plan:

- remove static IP assignments;
- use datastore service DNS;
- keep profile coupling explicit;
- version client images where breaking major drift is possible;
- validate persistent workspace/data volumes;
- ensure clients tolerate target DB starting later (health/retry rather than immediate failure where possible).

## PHP / Node Runtime Dockerfiles

### `docker/dockerfiles/php.Dockerfile`

- keep `ARG PHP_VERSION` + upstream `php:<version>-fpm-alpine` model;
- add `SCRIPTOMATIC_REF` and `TOOLSET_REF`/related immutable dependency inputs;
- stop fetching setup script from floating Scriptomatic master;
- preserve UID/GID, extension/package and profile-key build args;
- validate image as non-root developer user and PHP-FPM service;
- keep build local because combinations are user-selected.

### `docker/dockerfiles/node.Dockerfile`

- keep selectable upstream Node Alpine version;
- pin Scriptomatic/Toolset helper revisions;
- preserve UID/GID/packages/globals customization;
- preserve non-root user;
- validate npm/corepack and project startup behavior;
- keep build local.

## Docker Config Files

### `docker/conf/filebeat.yml`

- validate against current Filebeat/Elasticsearch major;
- paths must match mounted LocalDevStack log layout;
- no fixed IP endpoints.

### `docker/conf/openssl.cnf`

- validate local dev compatibility with generated certificates/current OpenSSL;
- avoid weakening global TLS unnecessarily;
- document why overrides exist.

### `docker/conf/pg_hba.conf`

- review trust/auth scope for isolated local Docker network;
- preserve password auth expectations;
- no fixed subnet assumptions after network migration.

### `docker/conf/postgresql.conf`

- decide whether it remains intentionally unused/commented or should become active;
- if unused, avoid presenting it as active configuration in docs;
- if enabled, version-test it.

### `docker/conf/www-php.conf`

- validate FPM pool include/listen behavior against generated per-domain pools;
- ensure user/group/socket permissions align with Nginx/Apache access.

### `docker/conf/www.conf`

- classify as reference/upstream-derived vs active file;
- remove/deprecate if no runtime path consumes it, but only after search/tests.

## Generated/User Configuration Directories

### `configuration/compose/`

Continue as generated Compose overrides. Add validation that generated files are valid and stale overrides can be detected/cleaned safely.

### `configuration/php/php.ini`

Remain user override file. Provide documented defaults/examples rather than overwriting user edits during update.

### `configuration/scheduler/cron-jobs/`

Remain user/generated scheduler definitions. Validate filename/permissions/content before Runner consumes them.

### `configuration/scheduler/supervisor/`

Remain user/generated supervisor definitions. Validate configs before stack restart.

### `configuration/sops/config`, `global`, `keys`

Keep sensitive/state files ignored. Tighten permissions via setup without committing contents.

### `configuration/ssh/`

Keep optional read-only mount. Never copy private keys into images.

### `configuration/ssl/`

Keep generated cert artifacts/state according to the chosen named-volume/bind-mount model. Reconcile docs with actual source of truth.

## Logs

### `logs/`

- keep host-visible logs where that is a deliberate developer feature;
- avoid `chmod -R 777` if cross-platform/container UID tests show a safer workable model;
- if permissive mode remains necessary, document local-only rationale;
- ensure rotation behavior matches Runner configuration.

## Optional AI Compose Integration

### New `docker/compose/ai.yaml`

Add only after core networking/catalog changes are stable.

Service design:

- profile `ai` (or `llm`, decide one canonical public name);
- default published image `infocyph/llm-sm:<tested-version>` through env variable;
- AMD selectable through `amd-<version>` tag, not second repository;
- named volume -> `/root/.ollama`;
- optional project/workspace mount -> `/workspace`;
- loopback host port optional/configurable;
- join network for service-DNS access from other containers;
- GPU options handled through explicit override/profile rather than auto-detect magic that makes Compose unreliable across hosts.

Graphify/editor/other clients remain external consumers of the endpoint.

## Image Version Defaults

### New `docker/images.env` or equivalent committed defaults

Define compatibility-tested infrastructure image versions centrally, for example conceptual keys:

- `LDS_TOOLS_IMAGE=infocyph/tools:<version>`
- `LDS_RUNNER_IMAGE=infocyph/runner:<version>`
- `LDS_NGINX_IMAGE=infocyph/nginx:<version>`
- `LDS_APACHE_IMAGE=infocyph/apache:<version>`
- `LDS_LLM_IMAGE=infocyph/llm-sm:<version>` when AI enabled.

User `.env` may override them. A LocalDevStack release should not depend solely on whatever `latest` means that day.

## Documentation Files

### `docs/concepts/architecture.rst`

Update architecture diagram/responsibility boundaries, canonical catalog, optional AI and DNS-based networking.

### `docs/concepts/profiles-and-env.rst`

Document canonical catalog, env override precedence, infrastructure image versions and generated runtime profiles.

### `docs/concepts/storage-layout.rst`

Reconcile named volumes vs host `configuration/` directories. Clearly distinguish:

- persisted Docker named volumes;
- host-generated config;
- project source mounts;
- logs;
- secrets/SSH;
- optional AI model volume.

### `docs/quickstart.rst`

Update after final CLI flow is stable; keep XAMPP-like beginner path concise.

### `docs/guides/domain-setup.rst`

Document Docker-DNS routing and domain creation without static IP assumptions.

### `docs/guides/tls-and-certificates.rst`

Keep cross-platform trust instructions synchronized with actual `lds certificate` behavior.

### `docs/guides/secrets-sops-age.rst`

Validate against current Tools `senv` contract.

### `docs/guides/notifications.rst`

Validate notifier contract and clarify optional nature.

### `.readthedocs.yaml` / `docs/conf.py` / `docs/requirements.txt`

Pin/document docs dependencies enough for reproducible docs builds; validate Read the Docs build in CI if useful.

## Static Networking Migration Sequence

1. Add CI/tests resolving all services by DNS name.
2. Search all product/support repos for fixed `172.28/29/30` dependencies.
3. Remove per-service `ipv4_address` declarations from Compose files.
4. Remove IPAM subnet/gateway blocks from `main.yaml`.
5. Run PHP/Node/DB/admin/domain/TLS integration tests.
6. Re-evaluate `lds vpn-fix`:
   - delete/deprecate if its only purpose was static-subnet conflict;
   - retain only independently useful VPN behavior with updated docs.

## Docker Socket Review Sequence

1. Trace every `docker` command in Tools/Runner and admin panel.
2. Categorize read vs write operations.
3. Determine if Runner requires socket directly or only specific mounted jobs do.
4. Determine if Tools requires full socket for domain/profile/admin functionality.
5. Keep required access for local-dev UX; remove redundant mounts.
6. Document trust boundary prominently.

## Acceptance Criteria

1. Product CI exists and covers CLI/Compose/runtime generation.
2. `lds` public command surface remains compatible after modularization.
3. Canonical service catalog is consumed by both LocalDevStack and Tools.
4. Infrastructure image defaults are compatibility-tested/pinnable instead of unconditional `latest`.
5. PHP and Node remain dynamically customizable local builds.
6. All core service communication works through Docker DNS without fixed IPv4 assignments.
7. Local domain/TLS flows work on supported host classes.
8. DB/cache/mail/admin clients persist data appropriately.
9. Runner/scheduler/supervisor workflows remain functional.
10. Docker socket mounts are justified and minimized.
11. Optional `llm-sm` profile works with persistent models and published images only.
12. Documentation matches actual networking/storage/runtime behavior.
