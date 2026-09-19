# docker-apache — File-by-File Development Plan

## Role

`infocyph/docker-apache` is the optional Apache backend used when a LocalDevStack project needs Apache semantics or compatibility while Nginx remains the public edge.

## Invariants

- Apache is optional, not a second mandatory edge.
- Nginx may reverse-proxy to Apache over Docker DNS.
- Generated vhosts remain externally mounted.
- FastCGI/PHP-FPM compatibility remains available.
- Local TLS compatibility may be retained for internal/direct Apache use, but host-facing TLS ownership remains with LocalDevStack’s edge design.

## Existing Files

### `.github/workflows/docker.publish.yml`

Replace the legacy workflow with the ecosystem release contract:

- current GitHub Action majors;
- release event publishes immutable `<release>` + `latest`;
- schedule rebuilds latest release source and publishes `latest` only;
- Buildx cache;
- Docker Hub + GHCR from same digest;
- provenance;
- concurrency guard and timeout;
- scheduled builds must never overwrite release-version tags.

### New `.github/workflows/check.yml`

Validate:

- shell syntax and ShellCheck;
- real Docker build;
- `httpd -t` after image construction;
- container startup and healthcheck;
- mounted vhost loading;
- representative reverse-proxy/FastCGI config if feasible with a small fixture;
- clean signal shutdown.

### `Dockerfile`

Plan:

- parameterize upstream `httpd` Alpine base line for controlled updates;
- replace mutable Scriptomatic/Toolset downloads with immutable/ref-driven dependencies;
- retain only packages needed by update/entrypoint/healthcheck and local TLS/FastCGI support;
- preserve `apache-mod-fcgid`, curl/CA, shell/locale requirements where still used;
- keep `WORKDIR /app` and vhost directory contract;
- let CI/workflow provide dynamic OCI revision/version metadata;
- do not make Apache own LocalDevStack certificate generation;
- verify whether exposing 443 internally is still useful; keep until routing tests prove it can be removed safely.

### `scripts/update_httpd.sh`

Current role: normalizes upstream `httpd.conf`, enables proxy/FastCGI/rewrite/SSL/HTTP2/headers/deflate and adds the mounted vhost include.

Plan:

- keep operation deterministic/idempotent;
- replace brittle line-edit logic only where tests demonstrate risk;
- validate every enabled module exists in the selected upstream image;
- ensure repeated image-build execution would not duplicate config lines;
- validate resulting `httpd.conf` with `httpd -t` during build/CI;
- review whether both `Listen 80` and `Listen 443` are required for current Nginx-to-Apache modes;
- keep `IncludeOptional conf/vhosts/*.conf` as the generated-vhost contract;
- remove self-deletion (`rm -f -- "$0"`) only if retaining the helper at runtime is useful for diagnostics; otherwise document that it is a build-only helper.

### `scripts/entrypoint.sh`

Plan:

- preserve minimal runtime setup and final `exec` semantics;
- validate mounted vhost permissions/readability before launch where useful;
- fail with clear output when core config is invalid instead of looping;
- avoid runtime mutation of user-generated vhosts unless explicitly required.

### `scripts/healthcheck.sh`

Plan:

- verify health check tests the actual Apache process/config rather than a route that depends on an optional project;
- prefer `httpd -t` plus local process/listener validation;
- keep healthcheck fast and independent of Nginx or PHP project availability.

### `README.md`

Update after implementation:

- describe Apache as an optional LocalDevStack backend;
- document mounted vhost path and expected upstream PHP-FPM relationship;
- document ports/network use without implying users should bind Apache directly on host by default;
- document tag/release semantics and healthcheck.

### `.dockerignore`

Keep build context minimal and verify scripts are included.

### `.gitignore` / `.gitattributes`

Keep unless test/generated artifacts require updates. Preserve LF shell files.

### `LICENSE`

No change.

## New Tests / Fixtures

Suggested:

- `tests/apache-config-smoke.sh`;
- `tests/vhost-smoke.sh`;
- `tests/fixtures/vhosts/basic.conf`;
- optional PHP-FPM mock/upstream fixture for proxy/FastCGI validation.

Do not require a full LocalDevStack environment for repository-level CI.

## Integration Follow-Up in LocalDevStack

After release:

- pin/raise `infocyph/apache` version;
- validate Nginx -> Apache HTTP and HTTPS/internal paths still used by generated templates;
- validate `.htaccess`/rewrite use cases that justify Apache mode;
- remove Apache fixed IPv4 assignment with the broader DNS networking migration;
- ensure Apache is enabled only by the relevant generated profile/domain configuration.

## Acceptance Criteria

1. Shell validation green.
2. Image builds successfully.
3. `httpd -t` green after generated base configuration.
4. Mounted representative vhost loads successfully.
5. Healthcheck is project-independent.
6. Release-version tags are immutable and schedule updates `latest` only.
7. Scriptomatic/Toolset inputs are immutable/ref-driven.
8. LocalDevStack Apache-mode domains continue working behind Nginx via Docker DNS.
