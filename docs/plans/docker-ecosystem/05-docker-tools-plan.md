# docker-tools — File-by-File Development Plan

## Role

`infocyph/docker-tools` is the LocalDevStack control-plane image. It owns domain/vhost generation, local certificate generation, profile/runtime selection helpers, secrets/environment tooling, monitoring, diagnostics, admin UI, reusable templates and the bridge between user intent and generated LocalDevStack configuration.

This is the largest supporting image and should be changed only after Scriptomatic/Toolset contracts plus Runner/Nginx/Apache image contracts are stable.

## Architectural Boundary

`docker-tools` should implement control-plane mechanisms. LocalDevStack should remain the owner of product orchestration policy.

Target split:

- Tools: render/validate/generate/inspect.
- LocalDevStack: decide which services/profiles/images are enabled and persist the canonical product configuration.

Avoid a second independent copy of service defaults inside Tools when LocalDevStack can provide a machine-readable catalog.

## Existing Top-Level Files

### `.github/workflows/docker.publish.yml`

Replace legacy publishing with the modern contract:

- current Action majors;
- release -> immutable `<release>` + `latest`;
- schedule -> latest published release source, `latest` tag only;
- Buildx cache;
- provenance;
- concurrency guard and timeout;
- same digest to Docker Hub/GHCR;
- no scheduled overwrite of version tags.

### New `.github/workflows/check.yml`

Add layered validation rather than one monolithic smoke command:

1. shell syntax/ShellCheck;
2. PHP syntax for admin-panel PHP files;
3. template fixture rendering;
4. existing `senv-smoke.sh`;
5. Docker image build;
6. container startup/health/control-plane smoke;
7. machine-readable command output validation (`--json` contracts);
8. admin panel endpoint smoke.

### `Dockerfile`

Plan:

- parameterize Alpine base version;
- replace mutable Scriptomatic/Toolset `ADD` sources with immutable/ref-driven fetches;
- pin/verify mkcert, lazydocker and other downloaded executable sources where practical;
- review runtime-version discovery from endoflife.date: keep generated snapshot useful, but make build failure behavior intentional if external API is unavailable;
- preserve tools actually needed by shell commands/admin panel;
- remove duplicate packages only after command-to-package inventory;
- keep Docker CLI/Compose because control-plane commands currently inspect/manage stack containers;
- keep PHP runtime because admin panel is PHP-based;
- generate/store OCI source/version/revision metadata;
- add an image healthcheck covering the primary daemon/admin endpoint if one is stable;
- document Docker-socket trust expectation without attempting to solve host orchestration inside the Dockerfile.

### `README.md`

Rewrite only after behavior stabilizes. Document:

- control-plane responsibility;
- command inventory grouped by domain/TLS/env/monitoring/admin/runtime generation;
- required mounts and Docker socket implications;
- machine-readable interfaces consumed by LocalDevStack;
- release/tag policy;
- standalone limitations vs full LocalDevStack.

### `.dockerignore`

Verify admin assets/templates/tests required during build are not accidentally excluded. Keep build context minimal.

### `.gitignore` / `.gitattributes`

Preserve LF shell policy and add generated test artifacts only if needed.

### `LICENSE`

No change.

## Shell Command Files

### `scripts/shells/entrypoint.sh`

- define one clear primary process lifecycle;
- start notifier/admin services deterministically;
- propagate signals and child failures correctly;
- validate writable/mounted state directories before starting;
- avoid silently creating product configuration that should be owned by LocalDevStack.

### `scripts/shells/certify.sh`

- preserve mkcert/local CA workflow;
- make inputs/outputs explicit and idempotent;
- validate SAN/domain lists;
- keep generated CA/server cert paths compatible with Nginx/Apache/Mailpit/PHP trust mounts;
- add smoke generation + verification with `openssl`.

### `scripts/shells/mkhost.sh`

This is a critical large script.

- freeze current CLI/output contracts with fixtures before refactor;
- separate parsing/state/render orchestration internally only after tests exist;
- consume a canonical runtime/service catalog supplied by LocalDevStack instead of hard-coded duplicate product defaults where possible;
- validate project/document-root paths;
- generate PHP/Apache/Nginx/Node artifacts atomically;
- keep `--JSON`/state output stable for `lds`;
- make repeated creation idempotent;
- add PHP direct-FPM, PHP+Apache and Node fixture tests.

### `scripts/shells/rmhost.sh`

- mirror `mkhost` state semantics;
- delete only artifacts owned by the selected host;
- preserve unrelated shared config;
- make deletion idempotent;
- test create -> remove -> recreate lifecycle.

### `scripts/shells/domain-which.sh`

- keep read-only diagnostics;
- validate all supported generated config locations;
- machine-readable output where already supported must remain stable;
- no mutation side effects.

### `scripts/shells/env-store.sh`

- formalize JSON file schema/version;
- atomic writes + locking where concurrent admin/CLI access can occur;
- explicit error on malformed state instead of silent data loss;
- stable `get/set/unset/get-json/set-json` contracts;
- unit-style smoke tests with temporary files.

### `scripts/shells/profile-chooser.sh`

Current issue: duplicates LocalDevStack database profile/default definitions.

Target:

- accept a service catalog path/environment input;
- keep only generic selection/state mechanics in Tools;
- provide fallback built-in catalog only if standalone compatibility requires it;
- keep JSON/profiles/services/env outputs stable during migration;
- LocalDevStack becomes canonical source for profile names/default environment values.

### `scripts/shells/composer-setup.sh`

- pin Composer installer/source validation;
- verify checksum/signature flow if not already present;
- keep build-only responsibility narrow.

### `scripts/shells/git-default.sh`

- preserve mounted global Git config behavior;
- avoid overwriting explicit user config unexpectedly;
- support missing name/email cleanly;
- test idempotency.

### `scripts/shells/init-php-dirs.sh`

- keep directory initialization idempotent;
- validate permission model against PHP runtime UID/GID strategy;
- avoid world-writable defaults unless required by cross-UID volume behavior and documented.

### `scripts/shells/senv.sh`

- keep SOPS/Age operations explicit;
- preserve current smoke test;
- add malformed/missing-key behavior tests;
- never print decrypted secret material in diagnostics by default.

### `scripts/shells/es-policy.sh`

- validate Elasticsearch version/API compatibility;
- keep bootstrap idempotent;
- do not make Elasticsearch profile startup depend on Kibana availability unless necessary.

### `scripts/shells/notifierd.sh`

- treat notifier as optional support service;
- failures must not take down unrelated control-plane functions;
- validate FIFO/TCP/token behavior and clean shutdown.

### `scripts/shells/notify.sh`

- graceful no-listener behavior;
- strict input escaping;
- preserve existing host-notification protocol.

### `scripts/shells/status.sh`

- make service status read-only;
- prefer Docker labels/service names over static container IPs;
- stable human + machine-readable output if exposed.

### Monitoring scripts

Files:

- `monitor-flows.sh`
- `monitor-runtime.sh`
- `monitor-tls.sh`
- `monitor-db.sh`
- `monitor-volumes.sh`
- `monitor-queue.sh`
- `monitor-slo.sh`
- `monitor-log-heatmap.sh`
- `monitor-drift.sh`
- `monitor-alerts.sh`

For every file:

- classify required Docker/socket/log mounts;
- keep operation read-only unless the command explicitly advertises remediation;
- add timeout/error handling around Docker/network calls;
- return predictable exit status for automation/admin panel;
- support missing optional services without false critical errors;
- emit structured output for admin-panel consumption where practical;
- add fixture/smoke coverage per monitor category.

## Docker Runtime Templates

### `scripts/docker-templates/php.compose.yaml`

- preserve local image build (`localdevstack-php:<version>` + `pull_policy: never`);
- keep UID/GID/version/extensions/packages customization;
- fix any default GID inconsistency (`root` vs numeric) during implementation after validation;
- consume canonical paths/env from LocalDevStack;
- remove static IP assumptions;
- ensure healthcheck reflects PHP-FPM readiness;
- keep shared composer/Git/CA/FPM mounts.

### `scripts/docker-templates/node.compose.yaml`

- preserve local image build (`localdevstack-node:<version>`);
- keep UID/GID/version/package/global-package customization;
- keep Node app command/port/host generation explicit;
- remove static IP assumptions;
- validate healthcheck for apps that intentionally have delayed startup;
- keep Git/CA/SSH/project mounts.

## FPM Templates

Files:

- `scripts/fpm-templates/local-dynamic-warm.conf.tpl`
- `scripts/fpm-templates/local-ondemand.conf.tpl`
- `scripts/fpm-templates/local-static-high.conf.tpl`

Plan for each:

- render with fixture values;
- validate with `php-fpm -t` in representative PHP versions;
- document intended workload profile;
- keep local-dev defaults bounded to avoid excessive idle processes;
- ensure socket/user/group permissions match generated runtime containers and Nginx/Apache readers.

## HTTP Templates

Directories under `scripts/http-templates/` are contract-critical generated artifacts.

For every template file:

- render from a fixture replacing all placeholders;
- reject unresolved `{{...}}` tokens;
- Nginx templates must pass `nginx -t` in the target image;
- Apache templates must pass `httpd -t` in the target image;
- use Docker service/container DNS names rather than fixed IPs;
- preserve PHP direct-FPM, Apache proxy, Node proxy and fixed-IP/external-proxy modes only where still intentional;
- centralize common timeout/header snippets in image-level includes instead of duplicating large blocks across templates;
- keep TLS paths aligned with `certify.sh` output.

Known critical families include Node Nginx HTTP/HTTPS, PHP Nginx direct/proxy HTTP/HTTPS, Apache vhosts and fixed/external proxy templates.

## Admin Panel

### `scripts/admin-panel/app/bootstrap.php`

- centralize environment/path/container-name configuration;
- add safe wrappers for shell/Docker execution;
- enforce output escaping helpers and timeouts;
- keep no-framework deployment unless complexity justifies otherwise.

### `scripts/admin-panel/app/index.php` and `scripts/admin-panel/index.php`

- keep routing/front-controller behavior minimal;
- explicit 404/invalid page handling;
- no arbitrary file inclusion from request input.

### Layout files

- `_layout_top.php`
- `_layout_bottom.php`

Plan:

- centralize navigation/asset loading;
- keep all user/container data escaped;
- expose product/image version info for diagnostics.

### Operational pages

Files:

- `automation_cron.php`
- `automation_manager.php`
- `automation_supervisor.php`
- `dashboard.php`
- `db_health.php`
- `docker_logs.php`
- `drift_monitor.php`
- `host_manager.php`
- `live_stats.php`
- `logs.php`
- `queue_health.php`
- `slo_view.php`
- `tls_monitor.php`
- `volume_monitor.php`

For every page:

- separate data collection/action execution from HTML rendering where practical;
- add command timeout/error handling;
- validate/allowlist any container/service/path/action parameters;
- escape all output;
- require explicit confirmation/POST semantics for mutating actions;
- keep read-only monitoring pages non-mutating;
- align with the corresponding shell monitor/helper as the backend contract rather than duplicating logic in PHP;
- add PHP syntax checks and HTTP smoke tests.

### `scripts/admin-panel/public/css/core.css` / `panel.css`

- no redesign during hardening;
- remove duplication only when tied to admin panel maintainability;
- preserve offline assets.

### `scripts/admin-panel/public/js/core.js` / `panel.js`

- identify whether `core.js` is vendored/minified third-party content vs project source;
- do not hand-edit generated/vendor bundles without a source/update path;
- validate SSE/log-tail reconnect behavior;
- sanitize DOM insertion of runtime/container data.

### `scripts/admin-panel/public/vendor/**`

- record upstream package/version/license;
- keep vendored assets offline-capable;
- update only through an explicit dependency update step, not ad hoc edits.

### `scripts/admin-panel/README.md`

Update after contracts stabilize with page/backend architecture and standalone diagnostic instructions.

## Tests

### Existing `scripts/tests/senv-smoke.sh`

Keep and run in CI.

### New tests

Add focused tests instead of one giant integration script:

- env-store schema/atomicity;
- profile-chooser with injected catalog;
- mkhost/rmhost lifecycle fixtures;
- certificate generation/inspection;
- PHP/Node Compose template rendering;
- FPM template rendering + `php-fpm -t`;
- HTTP template rendering + Nginx/Apache config validation;
- monitor command no-service/degraded-service behavior;
- admin-panel PHP syntax + endpoint smoke;
- entrypoint/notifier startup.

## Canonical Service Catalog Migration

Create a machine-readable catalog contract owned by LocalDevStack, likely JSON/YAML in the LocalDevStack repository.

`docker-tools` should read the mounted catalog for:

- profile slug;
- service display name;
- default image/version variable;
- setup environment prompts/defaults;
- optional admin/convenience route metadata where appropriate.

Migration order:

1. Tools supports external catalog while retaining current fallback.
2. LocalDevStack adds canonical catalog and mounts it.
3. `lds` and Tools both consume it.
4. Remove duplicated hard-coded catalog only after compatibility tests pass.

## Acceptance Criteria

1. All maintained shell files pass syntax/ShellCheck policy.
2. Admin PHP files pass syntax and smoke tests.
3. Image builds and starts successfully.
4. External Scriptomatic/Toolset/helper downloads are immutable/ref-driven.
5. PHP/Node Compose templates render valid Compose.
6. FPM/HTTP templates render without unresolved placeholders and validate in target runtimes.
7. mkhost/rmhost create/delete lifecycle passes fixture tests.
8. cert generation and TLS inspection pass.
9. monitor/admin paths handle missing optional services correctly.
10. scheduled publication updates only `latest`; release tags remain immutable.
11. Tools can consume a LocalDevStack-supplied canonical service catalog.
12. No control-plane feature requires LocalDevStack fixed container IPs.
