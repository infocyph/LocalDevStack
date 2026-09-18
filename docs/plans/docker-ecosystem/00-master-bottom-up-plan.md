# LocalDevStack Docker Ecosystem — Bottom-Up Development Plan

## Status

Planning branch: `plan/docker-ecosystem-bottom-up`

Lower-layer work is now complete and published. The active phase is LocalDevStack product integration.

Completed/published baseline as of 2026-09-18:

- Shared foundations: Scriptomatic hardened on `main`, Toolset `2.0`
- `infocyph/runner:0.5`
- `infocyph/nginx:0.4.1`
- `infocyph/apache:0.4.2`
- `infocyph/tools:0.23.2`
- `infocyph/llm-sm:0.03` / `amd-0.03`

The authoritative active implementation plan is now `07-localdevstack-integration-plan.md`. Earlier 01–06 files remain historical planning records for the completed lower layers.

## Product Definition

LocalDevStack is a Docker-based local development platform for PHP and Node.js: a modern, modular XAMPP alternative with local domains/TLS, multiple PHP/Node runtimes, databases, admin UIs, mail, schedulers/workers, developer tools, and optional local AI.

The system is intentionally split across repositories instead of becoming one monolithic image.

## Repository Stack

Bottom to top:

1. `infocyph/Scriptomatic` — reusable bootstrap/entrypoint/setup scripts used while building developer/runtime images.
2. `infocyph/Toolset` — reusable standalone developer utilities consumed by images (`gitx`, `chromacat`, `sqlitex`, `netx`, etc.).
3. `infocyph/docker-runner` — background process infrastructure: Supervisor, cron, logrotate, helper execution.
4. `infocyph/docker-nginx` — primary HTTP/TLS edge and local routing.
5. `infocyph/docker-apache` — optional Apache backend for PHP/vhost compatibility.
6. `infocyph/docker-tools` — LocalDevStack control plane: domain/TLS/config generation, service/profile helpers, monitoring, admin panel, environment/secrets tooling.
7. `infocyph/docker-llm-sm` — published optional local-AI capability; already follows the newer image publication model.
8. `infocyph/LocalDevStack` — product/orchestrator: `lds`, Compose topology, PHP/Node runtime Dockerfiles, generated configuration, user-facing workflow, platform integration.

## Core Architectural Rules

### Published infrastructure vs generated runtimes

Published images remain independently versioned infrastructure:

- `infocyph/runner`
- `infocyph/nginx`
- `infocyph/apache`
- `infocyph/tools`
- `infocyph/llm-sm`

PHP and Node remain locally generated runtime images because they are customized by selected runtime version, host UID/GID, extensions/packages, and project-level needs:

- `localdevstack-php:<version>`
- `localdevstack-node:<version>`

Do not convert PHP/Node into one-size-fits-all published images unless a later design proves that customization can be retained without increasing user complexity.

### Image immutability contract

For every published `docker-*` repository:

- release event publishes `<release>` and `latest`;
- release-version tags are immutable after first publication;
- scheduled rebuild checks out the latest published release source but refreshes `latest` only;
- source release and resulting image revision must be identifiable through OCI metadata/provenance;
- Docker Hub and GHCR should receive the same built digest for the same variant.

`docker-llm-sm` is the reference implementation for this contract.

### Dependency reproducibility

Do not fetch executable build dependencies from floating `main`, `master`, or `latest` URLs without an explicit reason.

For Scriptomatic/Toolset files consumed during image builds:

- prefer a release tag when a release lifecycle exists;
- otherwise pin an immutable commit SHA;
- expose the selected ref as an explicit build argument where useful;
- record the selected ref in image labels/build metadata;
- verify downloaded content when practical.

Scheduled `latest` image rebuilds may consume updated base-image patches, but they must not mutate an already published version tag.

### Network contract

Service discovery should use Docker DNS/service names, not static container IPv4 addresses.

The current `172.28.0.0/24`, `172.29.0.0/24`, and `172.30.0.0/24` fixed LocalDevStack subnets are orchestration details, not image contracts. No supporting `docker-*` repository currently requires those addresses.

Migration target:

- retain logical networks (`frontend`, `backend`, `datastore`);
- remove fixed `ipv4_address` declarations;
- remove hard-coded IPAM subnets/gateways after validation;
- use service names/aliases for all cross-container communication;
- reassess `lds vpn-fix` after static-subnet removal.

### Docker socket contract

`/var/run/docker.sock` is equivalent to powerful host Docker control. It must not be mounted merely for convenience.

During LocalDevStack integration review:

- inventory each Docker API operation used by `server-tools` and `runner`;
- decide whether both containers still require direct socket access;
- preserve required local-development functionality;
- document the trust boundary clearly;
- do not add a socket proxy unless it demonstrably reduces permissions without breaking the developer workflow.

### Cross-platform contract

Preserve Linux, macOS, WSL/Git Bash, and Windows Docker Desktop support where currently intended.

`lds.bat` remains a Windows bridge into the Bash control plane. Do not replace it with a Linux-only installation model.

## Execution Order

### Phase 0 — Shared foundations — COMPLETE

Plan: `01-shared-foundations-plan.md`

Stabilize Scriptomatic and Toolset consumption before rebuilding dependent Docker images. The purpose is not to redesign those repositories wholesale; it is to establish immutable dependency references, validation, and reusable contracts required by the Docker stack.

Exit gate:

- every downstream image can select immutable Scriptomatic/Toolset revisions;
- required helper scripts have syntax/smoke validation;
- no downstream migration depends on floating helper content.

### Phase 1 — Leaf infrastructure images — COMPLETE

Completed releases:

- Runner `0.5`
- Nginx `0.4.1`
- Apache `0.4.2`

Historical plans:

- `02-docker-runner-plan.md`
- `03-docker-nginx-plan.md`
- `04-docker-apache-plan.md`

Goals:

- modernize CI/publication;
- pin external helper inputs;
- validate scripts/configs before publication;
- keep each image narrowly focused;
- publish immutable release tags and scheduled `latest` only.

Exit gate for each image:

- PR validation green;
- actual image build green;
- health/smoke check green;
- release workflow follows immutable-version contract;
- LocalDevStack can consume the resulting release without behavior regression.

### Phase 2 — Control plane — COMPLETE

Plan: `05-docker-tools-plan.md`

This control-plane phase is complete and published as `infocyph/tools:0.23.2`.

Primary goals:

- establish strong CI around shell tools/templates/admin panel;
- pin all downloaded dependencies;
- make machine-readable contracts explicit;
- reduce duplicated platform configuration with LocalDevStack;
- preserve domain/TLS/secrets/monitoring/admin workflows;
- avoid turning `docker-tools` into the owner of LocalDevStack orchestration policy.

### Phase 3 — Local AI capability — COMPLETE

Plan: `06-docker-llm-sm-plan.md`

`docker-llm-sm` is published as `0.03` and its provider/runtime contract is complete for this program.

Primary goals:

- keep its newer release model intact;
- define how LocalDevStack optionally enables CPU/NVIDIA/AMD tags;
- persist `/root/.ollama`;
- optionally mount project workspace for repo-aware AI commands;
- allow Graphify or other clients to use its Ollama endpoint without coupling them into the image.

### Phase 4 — Product/orchestrator — ACTIVE

Plan: `07-localdevstack-integration-plan.md`

Only after lower layers have stable contracts:

- add comprehensive CI;
- modularize the large `lds` control plane without changing the public CLI unnecessarily;
- establish one canonical service/profile catalog;
- migrate static networking to Docker DNS;
- reconcile generated-state/storage documentation with actual named volumes/bind mounts;
- consume versioned infrastructure images;
- integrate optional `llm-sm` cleanly;
- review Docker socket exposure;
- keep PHP/Node runtime generation flexible.

## Cross-Repository Release Strategy

Each infrastructure repository should independently release. LocalDevStack should consume explicit compatibility-tested versions rather than assuming every `latest` across the ecosystem changes safely together.

During development, `latest` remains useful. For LocalDevStack releases, prefer explicit image versions in the release manifest/default environment so a LocalDevStack release can be reproduced.

A later automated dependency update workflow may propose image version bumps after integration CI passes; do not couple repositories through automatic mutable `latest` behavior alone.

## Shared CI Baseline

Every `docker-*` repository should converge on an appropriate subset of:

- shell syntax checks (`bash -n` / `sh -n` as appropriate);
- ShellCheck for maintained shell scripts;
- Dockerfile/build validation via real Buildx build;
- container smoke/health check;
- configuration validation (`nginx -t`, `httpd -t`, `supervisorctl`, etc.);
- Docker metadata/provenance;
- Buildx cache with repository/variant-safe scopes;
- concurrency protection for publication;
- timeout limits for stuck builds;
- SBOM and vulnerability visibility where practical;
- scheduled `latest` refresh without version-tag overwrite.

Do not add CI that cannot exercise the image’s actual contract merely to increase check count.

## Planning Rules for File-by-File Drafts

Each repository plan below identifies:

- existing files to modify;
- existing files to validate but intentionally keep;
- new files/workflows/tests to create;
- cross-repository prerequisites;
- acceptance criteria.

Implementation should follow the listed order inside each repository unless a dependency discovered during coding requires adjustment.

## Non-Goals

This program is not intended to:

- replace Docker Compose;
- collapse all services into one container;
- convert LocalDevStack into Kubernetes;
- publish customized PHP/Node combinations for every possible user selection;
- remove Apache merely because Nginx is the default edge;
- make local-development containers production-hardening equivalents;
- introduce a new programming language for the CLI solely for refactoring aesthetics;
- add AI requirements to users who do not enable the AI capability.

## Definition of Completion

The ecosystem work is complete when:

1. Shared helper dependencies are reproducible and tested.
2. All published infrastructure images have modern immutable release workflows and meaningful CI.
3. `docker-tools` exposes stable machine-readable contracts instead of duplicating orchestration state where avoidable.
4. LocalDevStack has integration CI covering its major profile/runtime combinations.
5. Static IP dependence is removed unless a documented unavoidable case remains.
6. PHP and Node runtime generation remains version-flexible and user-customizable.
7. Local domains/TLS, mail, DB/admin clients, cron/supervisor, secrets, and diagnostics still work.
8. Optional local AI can be enabled through `infocyph/llm-sm` without contaminating the default stack.
9. Documentation matches the actual storage/network/release behavior.
10. A clean install on supported host categories can reach a working PHP or Node local domain with TLS using the documented workflow.
