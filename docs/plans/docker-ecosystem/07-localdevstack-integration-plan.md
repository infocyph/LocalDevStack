# LocalDevStack — Final Integration, Hardening & Productization Plan

## Status

Planning branch: `plan/docker-ecosystem-bottom-up`

Product repository: `infocyph/LocalDevStack`

Baseline:

- LocalDevStack `main`: `008c3266313d89dbc4e8243e0c1515447fdceaa9`
- Product role: Docker-based XAMPP/MAMP/LAMP alternative for PHP + Node.js development
- Primary CLI: `lds`
- Windows bridge: `lds.bat`
- Default HTTP/TLS edge: Nginx
- Optional compatibility backend: Apache
- PHP and Node runtimes: locally generated/customized images
- Infrastructure images: published, independently versioned images
- Local AI: optional, provider-backed, never required for the default stack

All lower-layer ecosystem work is complete and published. This file is now the authoritative implementation plan for the LocalDevStack phase and supersedes the earlier exploratory version of this plan.

## Published compatibility baseline

LocalDevStack implementation must begin against this tested ecosystem set:

| Layer | Contract |
| --- | --- |
| Scriptomatic | hardened `main`; downstreams may use `main` or an explicit full SHA |
| Toolset | stable `2.0` release/installer contract |
| Runner | `infocyph/runner:0.5` |
| Nginx | `infocyph/nginx:0.4.1` |
| Apache | `infocyph/apache:0.4.2` |
| Tools | `infocyph/tools:0.23.2` |
| LLM standard | `infocyph/llm-ollama:latest` |
| LLM AMD | `infocyph/llm-ollama:amd-latest` |

The implemented image policy now follows the ecosystem moving aliases for LocalDevStack
infrastructure. Standard LLM uses `latest`; AMD/ROCm uses `amd-latest`. Release
reproducibility is provided by each image repository's immutable release tags, provenance
and compatibility gates rather than by duplicating pinned image versions in
LocalDevStack configuration.

---

# 1. Product definition

LocalDevStack is not a generic production orchestrator.

It is a local developer workstation product intended to provide the convenience of XAMPP/MAMP/LAMP while retaining Docker isolation and modern PHP/Node workflows.

The product should make these workflows easy:

1. install/initialize once;
2. choose services and runtimes;
3. create a local domain;
4. get trusted local HTTPS;
5. run PHP/Composer and Node/npm tooling;
6. use databases and their admin clients;
7. use local mail;
8. run cron/Supervisor workers;
9. inspect status/logs/health;
10. optionally enable local AI without changing the core stack.

Docker remains the implementation mechanism, not the user experience.

---

# 2. Final architecture

Target architecture:

```text
Host
 │
 ├── lds / lds.bat
 │      │
 │      ├── setup / profiles / domains / certificates
 │      ├── runtime generation
 │      ├── service wrappers
 │      └── Compose orchestration
 │
 └── Docker
        │
        ├── nginx 0.4.1
        │     ├── project.localhost -> PHP / Apache / Node
        │     ├── admin.localhost   -> server-tools:9911
        │     ├── webmail.localhost -> mailpit:8025
        │     ├── db/ri/me/kibana convenience routes
        │     └── llm-ollama.localhost     -> llm-ollama:11434
        │
        ├── apache 0.4.2 (optional backend)
        ├── PHP runtimes (local builds)
        ├── Node runtimes (local builds)
        ├── server-tools 0.23.2
        │     ├── host/domain/TLS/config control plane
        │     ├── monitoring/admin panel
        │     ├── askai / aiops / gitx AI consumer paths
        │     └── http://llm-ollama:11434
        │
        ├── runner 0.5
        │     └── Supervisor / cron / logrotate / sibling exec
        │
        ├── mailpit
        ├── databases and admin clients
        │
        └── llm-ollama current stable (optional)
              ├── qwen3.5:9b baked default
              ├── persistent /root/.ollama
              └── Ollama API :11434
```

Service-to-service AI traffic must use:

```text
http://llm-ollama:11434
```

Host/user-facing AI traffic must use:

```text
https://llm-ollama.localhost
```

Do not route Tools -> LLM traffic through Nginx.

---

# 3. Product invariants

These are hard constraints for the LocalDevStack phase.

## 3.1 CLI and platform

- `lds` remains the primary user-facing CLI.
- `lds.bat` remains the Windows/Git-Bash bridge.
- Existing public commands/aliases should remain compatible unless a command is proven obsolete.
- Refactoring the implementation must not force users to learn Docker Compose internals.
- Linux, macOS, WSL/Git Bash and Windows Docker Desktop behavior must remain intentionally supported where the current product already targets them.

## 3.2 Runtime model

- PHP remains locally generated from official `php:<version>-fpm-alpine`.
- Node remains locally generated from official `node:<version>-alpine`.
- User-selected packages/extensions/globals remain supported.
- Host UID/GID alignment remains supported.
- Project source remains bind-mounted; it is never baked into infrastructure images.

## 3.3 HTTP model

- Nginx remains the only default host-facing HTTP/TLS edge.
- Apache remains optional.
- Local certificates remain generated/owned by LocalDevStack/Tools, not Nginx or Apache.
- Project routing and infrastructure routing must use Docker DNS/service names.
- Static container IPs are not product contracts.

## 3.4 State model

The following must survive container recreation:

- database data;
- Redis data where persistence is enabled;
- Mailpit data;
- LocalDevStack generated/shared state;
- Composer global state where currently persisted;
- Git config state where currently persisted;
- AI model state under `/root/.ollama`.

Deleting volumes must remain an explicit destructive action.

## 3.5 AI model

- AI is optional.
- `docker-tools` is an AI consumer, never an Ollama runtime.
- `docker-llm-ollama` is the only LocalDevStack Ollama/model runtime.
- LocalDevStack must remain fully usable when `llm-ollama` is absent.
- No automatic execution of model-generated shell, SQL or code is introduced.
- No external/cloud AI fallback is added by LocalDevStack.
- No Docker socket is mounted into `llm-ollama`.
- No repository/workspace is mounted into `llm-ollama` by default.

## 3.6 Single-stack compatibility

The current product uses fixed container names and globally named volumes.

For this release:

- preserve those names unless a concrete bug requires change;
- do not combine the networking migration with a container/volume naming migration;
- document that the current architecture is optimized for one LocalDevStack installation per Docker engine.

Multi-stack namespacing may be a later project. It must not risk existing user data in this integration release.

---

# 4. Implementation strategy

The LocalDevStack work should be implemented bottom-up inside this repository.

Do not begin by splitting the 100+ KB `lds` file.

First establish CI and compatibility characterization, then change orchestration, then modularize code.

Each implementation batch has three phases:

1. **Implement** — make the bounded change.
2. **Validate** — static/unit/Compose/runtime checks.
3. **Integrate** — exercise the change through `lds` and the published images.

Recommended order:

- Batch 1 — CI + characterization
- Batch 2 — release/image defaults
- Batch 3 — networking/DNS migration
- Batch 4 — optional AI integration
- Batch 5 — profiles/catalog/runtime defaults
- Batch 6 — PHP/Node build modernization
- Batch 7 — `lds` modularization + wrapper cleanup
- Batch 8 — config/log/socket hardening
- Batch 9 — documentation/QoL/release gate

A batch should leave the branch usable before moving to the next one.

---

# 5. Batch 1 — CI and behavior characterization

## 5.1 New `.github/workflows/check.yml`

This is the first implementation task.

Required jobs:

### Static shell validation

Validate:

- `lds`;
- executable files under `bin/`;
- new `lib/*.sh` modules once introduced;
- maintained shell fixtures.

Use:

- `bash -n`;
- ShellCheck with explicit, documented suppressions only.

Do not globally ignore broad ShellCheck classes to make CI green.

### Batch/Windows bridge validation

At minimum:

- parse/static-check `lds.bat` expectations;
- validate paths containing spaces;
- validate Git-for-Windows Bash discovery assumptions;
- validate caller working-directory preservation.

A Windows runner should be added for bridge-specific smoke tests when practical.

Do not duplicate the entire Linux Docker integration suite on Windows.

### Compose validation

Run `docker compose config` for representative matrices:

- core only;
- core + Apache;
- each DB profile;
- Elasticsearch + Kibana/Filebeat;
- AI CPU;
- AI NVIDIA override config syntax;
- AI AMD override config syntax;
- generated PHP runtime;
- generated Node runtime.

Compose validation must catch missing variables, duplicate keys, invalid profiles and invalid override merges.

### CLI characterization

Add non-destructive tests for:

- `lds help`;
- `lds setup` routing;
- profile parsing;
- dotenv reads/writes;
- compose-file resolution;
- runtime selection;
- aliases;
- status/doctor/config commands;
- domain argument validation;
- unknown-command handling;
- commands that should work without Docker where applicable.

### Published-image core integration

Use the exact compatibility baseline:

```text
infocyph/tools:0.23.2
infocyph/runner:0.5
infocyph/nginx:0.4.1
infocyph/apache:0.4.2
```

Validate:

- Tools reaches healthy state using its own healthcheck;
- Runner reaches healthy state;
- Nginx validates and starts;
- Apache validates and starts when enabled;
- `admin.localhost` routes to Tools;
- core containers resolve each other through Docker DNS;
- clean SIGTERM/Compose down behavior.

### AI integration smoke without model download

Do not download a 3B model on every LocalDevStack PR.

Use a lightweight fake Ollama-compatible service named `llm-ollama` for the normal PR test.

Validate:

- Tools `askai --status` reaches `http://llm-ollama:11434`;
- Tools `aiops provider` works;
- Nginx `llm-ollama.localhost` reaches the fake service;
- streamed response is not buffered incorrectly;
- AI absence leaves core services healthy.

A manual/release-gate job may optionally exercise the real published `infocyph/llm-ollama:latest`, because that image already has its own model-bearing runtime gate.

## 5.2 New `tests/`

Suggested layout:

```text
tests/
  lib/
    assertions.sh
    fixtures.sh
  static.sh
  cli-contract.sh
  env-contract.sh
  compose-contract.sh
  networking-contract.sh
  runtime-php-contract.sh
  runtime-node-contract.sh
  ai-contract.sh
  release-gate.sh
  fixtures/
    env/
    compose/
    projects/
    fake-ollama/
```

Keep fixtures disposable.

Never commit real certificates, private keys, SOPS keys or user secrets.

---

# 6. Batch 2 — Release defaults and image policy

## 6.1 Tracked `docker/release.env`

The implemented release manifest contains only defaults that genuinely vary independently
of the fixed product Compose definitions. Current tracked value:

```text
SCRIPTOMATIC_REF=main
```

Tools, Runner, Nginx and Apache are declared directly as their moving `:latest` product
images. The tracked Ollama service is declared directly as
`infocyph/llm-ollama:latest`. AMD/ROCm uses a temporary runtime override that directly
selects `infocyph/llm-ollama:amd-latest`; there is no separate LLM image-tag selector.

Do not add `LDS_TOOLS_IMAGE`, `LDS_RUNNER_IMAGE`, `LDS_NGINX_IMAGE`,
`LDS_APACHE_IMAGE`, `LDS_LLM_IMAGE`, or `LDS_LLM_AMD_IMAGE` indirection.

Rules:

- `docker/release.env` is release-owned;
- user LocalDevStack overrides belong in `docker/.env`;
- command-scoped shell values retain the highest interpolation precedence;
- do not copy release defaults into a user file on every update;
- upgrades should not overwrite user values;
- precedence must remain deterministic and covered by tests.

## 6.2 Compose image references

Replace hard-coded:

```text
infocyph/tools:latest
infocyph/runner:latest
infocyph/nginx:latest
infocyph/apache:latest
```

with:

```yaml
image: ${LDS_TOOLS_IMAGE:-infocyph/tools:0.23.2}
image: ${LDS_RUNNER_IMAGE:-infocyph/runner:0.5}
image: ${LDS_NGINX_IMAGE:-infocyph/nginx:0.4.1}
image: ${LDS_APACHE_IMAGE:-infocyph/apache:0.4.2}
```

Do the equivalent for `llm-ollama`.

## 6.3 Update command / future dependency bumps

Do not silently mutate release defaults at runtime.

A future QoL command may report newer releases, for example:

```text
lds update check
```

but it should not rewrite compatibility pins without explicit user action.

A future CI workflow may test proposed dependency bumps and open a PR, but that is not required to complete this phase.

---

# 7. Batch 3 — Remove static-IP architecture

This is the largest orchestration cleanup before AI/profile work.

## 7.1 `docker/compose/main.yaml`

Keep logical networks:

- `frontend`;
- `backend`;
- `datastore`.

Remove:

- hard-coded `172.28.0.0/24`;
- hard-coded `172.29.0.0/24`;
- hard-coded `172.30.0.0/24`;
- explicit gateway declarations.

Target:

```yaml
networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
  datastore:
    driver: bridge
```

Preserve current labels where they are useful for LocalDevStack discovery.

Do not rename networks in the same migration unless necessary.

## 7.2 `docker/compose/companion.yaml`

Remove all `ipv4_address` entries.

Preserve service DNS names:

- `server-tools`;
- `runner`;
- `mailpit`.

Retain the network membership actually required by each service.

Do not attach services to every network merely for convenience.

## 7.3 `docker/compose/http.yaml`

Remove fixed Nginx/Apache addresses.

Nginx must route by service name only.

Preserve:

- host `80/443` bindings;
- vhost volume;
- cert/root-CA mounts;
- FPM socket volume;
- logs;
- `host.docker.internal:host-gateway` only if a real supported path still requires it.

Normalize Apache restart behavior to `unless-stopped` unless a tested reason requires `always`.

## 7.4 `docker/compose/db.yaml`

Remove every datastore `ipv4_address`.

Keep hostnames/service names as the application contract:

- `redis`;
- `postgres`;
- `mysql`;
- `mongodb`;
- `mariadb`;
- `elasticsearch`.

## 7.5 `docker/compose/db-client.yaml`

Remove fixed addresses on both `frontend` and `datastore`.

Admin clients must use service DNS.

## 7.6 `lds vpn-fix`

Characterize the current behavior before removal.

If the command only exists to work around collisions created by LocalDevStack's fixed subnets:

- deprecate it in this release;
- keep a compatibility message for one release if useful;
- remove related routing mutation code after tests prove dynamic Docker networks solve the original problem.

If some independent VPN behavior is still useful, rename/re-scope the command to that actual function rather than preserving obsolete subnet assumptions.

## 7.7 Networking acceptance tests

Validate all of these without fixed IPs:

- Nginx -> Tools;
- Nginx -> Mailpit;
- Nginx -> DB UIs;
- Nginx -> Apache;
- Nginx -> Node app;
- Nginx -> llm-ollama;
- Tools -> DB/service diagnostics;
- Tools -> llm-ollama;
- Runner -> PHP/Node sibling execution;
- DB clients -> databases;
- Filebeat -> Elasticsearch;
- generated project vhosts.

---

# 8. Batch 4 — Optional local AI integration

AI should become a first-class optional LocalDevStack capability while remaining absent from the default stack.

## 8.1 Single `llm-ollama` service in `docker/compose/companion.yaml`

Base service:

```yaml
services:
  llm-ollama:
    container_name: LLM_OLLAMA
    image: infocyph/llm-ollama:latest
    restart: unless-stopped
    profiles: [ai]
    volumes:
      - lds_llm:/root/.ollama
    networks:
      - frontend
      - backend
```

Important rules:

- service key must be exactly `llm-ollama`;
- preserve the existing fixed container name `LLM_OLLAMA` for single-stack compatibility;
- route internally by the Compose service/hostname `llm-ollama`, not by the fixed container name;
- do not set a fixed IP;
- do not mount Docker socket;
- do not expose `11434` to all interfaces;
- do not add a host port in the base companion service;
- do not add an automatic repository/workspace mount;
- do not add cloud fallback.

Why both networks:

- Nginx must reach `llm-ollama:11434` for `https://llm-ollama.localhost`;
- Tools must reach `llm-ollama:11434` directly for AI consumer commands.

## 8.2 `docker/compose/main.yaml` volume

Add:

```yaml
lds_llm:
  name: LLMModels
```

or a similarly consistent LocalDevStack volume name.

Mount it to:

```text
/root/.ollama
```

The volume is authoritative runtime model state.

A fresh volume receives the image-baked `qwen3.5:9b`.

Existing populated volumes must never be silently replaced/reset during upgrades.

## 8.3 CPU / NVIDIA / AMD runtime selection

Use conservative capability detection to choose the initial runtime, while keeping explicit user override authoritative.

Provide explicit runtime modes:

```text
cpu
nvidia
amd
```

Do not create tracked runtime-variant Compose files. Keep one service in
`docker/compose/companion.yaml` and let `lds` generate a temporary
`docker/.runtime/ai.*` fragment for the current Compose invocation only.

NVIDIA:

- keep the tracked `infocyph/llm-ollama:latest` image;
- add `gpus: all` in the temporary fragment.

AMD:

- set `image: infocyph/llm-ollama:amd-latest` directly in the temporary fragment;
- expose `/dev/kfd` and `/dev/dri` in the temporary fragment.

`LDS_AI_RUNTIME` is the explicit runtime selector when configured. There is no
`LDS_LLM_ARCH` setting or user-facing image-version choice. Detection rules are:
usable `nvidia-smi` -> NVIDIA;
both `/dev/kfd` and `/dev/dri` -> AMD/ROCm; otherwise CPU. An AMD CPU alone never
selects the AMD/ROCm image. `lds llm runtime ...` remains the explicit override.

## 8.4 Native host API

LocalDevStack exposes Ollama only through Nginx. The provider container itself remains
internal and has no host port mapping.

Nginx owns both user-facing paths:

```text
https://llm-ollama.localhost
http://llm-ollama.localhost:11434
```

The native port is fixed and loopback-only on the host:

```text
127.0.0.1:11434 -> nginx:11434 -> llm-ollama:11434
```

Never bind the native Ollama route to `0.0.0.0:11434`.

## 8.5 Nginx integration

The Nginx image owns the dedicated TLS and native Ollama proxy routes:

```text
llm-ollama.localhost:443   -> llm-ollama:11434
nginx:11434                -> llm-ollama:11434
```

Both routes use lazy Docker DNS resolution and streaming proxy behavior. LocalDevStack
publishes Nginx's native listener as `127.0.0.1:11434:11434`.

LocalDevStack must validate:

- certificate coverage for `llm-ollama.localhost`;
- HTTP -> HTTPS redirect;
- `/api/tags`;
- `/api/generate`;
- `/api/chat`;
- OpenAI-compatible `/v1/...`;
- stream passthrough;
- expected 502/unavailable behavior when AI profile is disabled, without affecting Nginx startup.

## 8.6 Tools integration

Pass the published Tools AI contract into `server-tools`:

```text
LDS_AI_ENABLED=auto
LDS_AI_PROVIDER=ollama
LDS_AI_URL=http://llm-ollama:11434
LDS_AI_MODEL=qwen3.5:9b
```

Allow user overrides.

Also pass through supported advanced limits only when the user sets them:

- `LDS_AI_CONNECT_TIMEOUT=2`;
- `LDS_AI_PREFLIGHT_TIMEOUT=5`;
- `LDS_AI_TIMEOUT=1800`;
- `LDS_AI_AVAILABILITY_TTL=5`;
- `LDS_AI_MAX_CONTEXT_BYTES=524288`;
- `LDS_AI_MAX_REQUEST_BYTES=1048576`;
- `LDS_AI_MAX_RESPONSE_BYTES=2097152`.

Keep connection and preflight bounds short, but give generation/analysis a 30-minute
default. Forward `LDS_AI_TIMEOUT` to the Nginx container as
`LLM_PROXY_TIMEOUT_SECONDS` so the dedicated `llm-ollama.localhost` route has the same
long-running request budget. Do not reintroduce a shorter independent UI/process timeout
for Admin AI analysis.

Why LocalDevStack should default `LDS_AI_MODEL=qwen3.5:9b`:

- `llm-ollama:latest` ships that model;
- the 14B Qwen3 default provides materially stronger instruction/structured-output behavior than the previous 3B model while remaining practical on modern 32 GB unified-memory developer hosts;
- Tools intentionally reports ambiguity when multiple models are installed and no model is selected;
- users may pull more models without breaking Tools AI workflows.

Users can change `LDS_AI_MODEL` explicitly. LocalDevStack forwards it to the provider
as `LLM_OLLAMA_MODEL` so Tools and `lds llm` share the same default model.

Provider settings accepted through `docker/.env` and forwarded to `llm-ollama` are:

- `LLM_OLLAMA_SYSTEM`;
- `LLM_OLLAMA_INPUT_WARN_BYTES`;
- `LLM_OLLAMA_INPUT_MAX_BYTES`;
- `LLM_OLLAMA_ATTACHMENT_MAX_BYTES`;
- `LLM_OLLAMA_ATTACHMENTS_MAX_BYTES`;
- `LLM_OLLAMA_ATTACHMENT_MAX_COUNT`;
- `LLM_OLLAMA_PDF_MAX_PAGES`;
- `LLM_OLLAMA_PDF_DPI`;
- `LLM_OLLAMA_ALLOW_LARGE_INPUT`;
- `OLLAMA_NUM_PARALLEL`;
- `OLLAMA_MAX_LOADED_MODELS`;
- `OLLAMA_KEEP_ALIVE`;
- `OLLAMA_NO_CLOUD`.

These are provider/runtime controls and are distinct from the Tools consumer
`LDS_AI_*` timeout/context limits.

Do not make Tools pull/remove models.

## 8.7 AI CLI UX

Add a thin LocalDevStack surface without duplicating provider implementations.

Recommended commands:

```text
lds ai status
lds ai ask ...
lds ai explain ...
lds ai troubleshoot ...
lds ai review ...
lds ai repo-review ...
lds ai graphify ...
```

Map these to the published Tools commands:

- `askai`;
- `aiops`.

Recommended provider/model-management pass-through:

```text
lds llm models
lds llm ps
lds llm show [model]
lds llm pull <model>
lds llm rm <model>
lds llm unload [model]
lds llm run <model> ...
lds llm chat [model]
lds llm prompt ...
lds llm code ...
lds llm review ...
lds llm json ...
lds llm ai-commit ...
```

These should delegate to the bundled `llm-ollama` CLI inside the provider container.

LocalDevStack must not reimplement Ollama/model logic.

## 8.8 Workspace/repository access

Default: no project mount into `llm-ollama`.

Tools already has the LocalDevStack project mounted at `/app` and its AI layer applies size/sensitivity/redaction guards.

For direct `llm-ollama` repository-aware commands:

- prefer stdin/file transfer where practical;
- optionally provide a separate read-only workspace override;
- default the workspace mount to read-only;
- require explicit opt-in for writable workspace access.

Never automatically mount arbitrary host repositories.

## 8.9 Graphify

Do not install Graphify into either provider image or Tools solely for this integration.

Supported patterns:

- `lds graphify [path] [extract-options...]` -> host Graphify workflow against the
  common loopback-published `llm` endpoint, using the effective active-provider model
  and `LDS_AI_TIMEOUT` by default;
- FastFlow/NPU -> Graphify `openai` backend with `OPENAI_BASE_URL` /
  `OPENAI_MODEL` / `OPENAI_API_KEY`;
- Ollama/CPU/NVIDIA/ROCm -> Graphify `ollama` backend with `OLLAMA_BASE_URL` /
  `OLLAMA_MODEL` / `OLLAMA_API_KEY`;
- explicit external provider URLs remain caller-controlled through the matching
  backend-specific environment variables;
- Tools `aiops graphify --file <output>` -> analyze an explicitly supplied Graphify output file.

Local Graphify defaults to `--token-budget 3000 --max-concurrency 1` unless the caller
supplies explicit values. These defaults keep Qwen3.5 9B semantic extraction below the
practical local context ceiling that can otherwise produce `Max length reached!`.
`LDS_GRAPHIFY_TOKEN_BUDGET` and `LDS_GRAPHIFY_MAX_CONCURRENCY` override the
LocalDevStack defaults.

For a brand-new graph, `lds graphify` runs code-only `extract --no-cluster`, clusters
the structural graph, then runs a normal incremental `extract --no-cluster` to enrich
semantic files and clusters the combined graph. Existing graphs keep the single
incremental extract + `cluster-only` flow. Explicit `--code-only` remains single-phase.
Graphify remains a host/external consumer.

## 8.10 AI admin panel

Do not create a second AI web UI in LocalDevStack.

Use the AI capability already shipped in `tools:0.23.2` and exposed through:

```text
https://admin.localhost
```

LocalDevStack's responsibility is to provide correct provider env/networking.

---

# 9. Batch 5 — Profiles, defaults and service metadata

## 9.1 Current duplication

Today profile/service defaults exist in more than one place:

- LocalDevStack `lds`;
- Tools `profile-chooser`.

Because `tools:0.23.2` is already a published lower-layer contract, LocalDevStack must not require another Tools release to complete this phase.

## 9.2 LocalDevStack canonical host-side catalog

Add a host-side product catalog such as:

```text
docker/catalog/services.json
```

Use it for new/rewritten LocalDevStack profile logic.

Schema should support:

- profile key;
- display name;
- service key;
- image/version env key;
- default values;
- setup prompts;
- optional admin client;
- persistence volume;
- convenience URL;
- category;
- whether the service is optional/default;
- AI runtime metadata where appropriate.

Initial entries:

- PostgreSQL;
- MySQL;
- MariaDB;
- MongoDB;
- Redis;
- Elasticsearch;
- AI.

Do not place user secrets in the catalog.

## 9.3 Compatibility with Tools profile chooser

Do not block LocalDevStack release on making Tools consume the catalog.

For this release:

- LocalDevStack host setup uses its own catalog;
- Tools `profile-chooser` remains a compatible standalone Tools capability;
- add a contract test that detects material drift between LocalDevStack defaults and Tools defaults where they overlap.

A future Tools release may add external-catalog support. That is a later cleanup, not a prerequisite.

## 9.4 AI profile setup

Extend `lds setup profile` to include optional AI.

Prompt only relevant AI settings:

- enable AI yes/no;
- detected runtime is shown, not prompted by default;
- preferred model default `qwen3.5:9b`;
- optional direct localhost port yes/no.

Do not ask users for low-level timeout/byte-limit settings during normal setup.

Advanced variables remain manual env overrides.

---

# 10. Batch 6 — PHP and Node runtime build modernization

## 10.1 `docker/dockerfiles/php.Dockerfile`

Preserve:

```dockerfile
ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm-alpine
```

Replace stale Scriptomatic `master` download.

Introduce:

```dockerfile
ARG SCRIPTOMATIC_REF=main
```

Fetch:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/${SCRIPTOMATIC_REF}/bash/php-cli-setup.sh
```

Pass the same `SCRIPTOMATIC_REF` into the bootstrap so sibling Scriptomatic helpers come from the same revision.

Requirements:

- bounded curl retries/timeouts;
- verify non-empty script;
- `bash -n` before execution;
- retain UID/GID;
- retain package/extension args;
- retain PHP profile key;
- retain non-root developer user;
- retain FPM entrypoint;
- retain Composer-home separation.

Do not add a direct Toolset download to this Dockerfile. Scriptomatic owns the current Toolset stable installer contract.

Default may remain `SCRIPTOMATIC_REF=main`.

A LocalDevStack release or user may override it with a full SHA when exact reproducibility is needed.

## 10.2 `docker/dockerfiles/node.Dockerfile`

Apply the equivalent Scriptomatic contract:

```dockerfile
ARG SCRIPTOMATIC_REF=main
```

Preserve:

- selectable Node version;
- UID/GID;
- Linux packages;
- global Node packages;
- non-root user;
- npm/Corepack behavior;
- Node entrypoint.

## 10.3 Runtime image identity

Keep:

```text
localdevstack-php:<version/profile>
localdevstack-node:<version/profile>
```

Do not publish the combinatorial PHP/Node runtime matrix.

## 10.4 Build caching

Avoid rebuilding unchanged local runtime images unnecessarily.

The runtime-image identity/hash should account for inputs that affect the image:

- runtime version;
- Scriptomatic ref;
- UID/GID;
- selected extensions/packages/globals;
- relevant Dockerfile revision.

A later optimization may use labels or a deterministic configuration hash.

Do not let caching return a runtime built with different extension/package inputs.

---

# 11. Batch 7 — Modularize `lds` safely

The current `lds` file is over 100 KB.

Refactor only after Batches 1–6 have tests.

## 11.1 Target layout

```text
lds
lib/
  core.sh
  platform.sh
  env.sh
  compose.sh
  profiles.sh
  catalog.sh
  runtime.sh
  hosts.sh
  certificates.sh
  services.sh
  ai.sh
  diagnostics.sh
  maintenance.sh
```

Suggested ownership:

### `lds`

Only:

- bootstrap;
- global option parsing;
- command dispatch;
- help/version entrypoints.

### `lib/core.sh`

- output/error helpers;
- command requirements;
- common argument helpers;
- temporary-file helpers.

### `lib/platform.sh`

- OS/WSL detection;
- Docker Desktop detection where needed;
- path conversion helpers;
- browser/open helpers.

### `lib/env.sh`

- release env;
- user env;
- dotenv parse/write;
- precedence;
- safe quoting.

Never `source` arbitrary dotenv files as shell code.

### `lib/compose.sh`

- canonical Compose file list;
- profile resolution;
- optional overrides;
- Compose command wrapper;
- service status/health helpers.

### `lib/catalog.sh`

- validate/read `services.json`;
- list available services;
- expose setup fields/defaults.

### `lib/profiles.sh`

- setup menu;
- selected profile persistence;
- AI runtime selection;
- profile/env reconciliation.

### `lib/runtime.sh`

- PHP/Node version resolution;
- generated Compose fragments;
- local image naming/build/rebuild.

### `lib/hosts.sh`

- domain create/delete;
- vhost generation calls;
- reload validation.

### `lib/certificates.sh`

- CA creation/trust;
- certificate refresh;
- platform-specific trust store.

### `lib/services.sh`

- start/stop/restart/status/logs/open;
- convenience service URL mapping.

### `lib/ai.sh`

Only LocalDevStack orchestration/delegation:

- profile enabled?;
- compose override selection;
- `lds ai` -> Tools;
- `lds llm` -> llm-ollama;
- model/runtime status.

No provider implementation.

### `lib/diagnostics.sh`

- doctor;
- config;
- health;
- environment diagnostics.

### `lib/maintenance.sh`

- clean;
- disk;
- events;
- rebuild;
- safe destructive confirmations.

## 11.2 Refactor rules

- no module performs work just because it is sourced;
- avoid hidden mutation of global state;
- keep function-local variables local;
- do not replace clear shell with framework-like abstractions;
- preserve exit codes where wrappers rely on them;
- keep `set -euo pipefail` behavior deliberate;
- characterization tests must pass after every extraction;
- one subsystem at a time.

---

# 12. Batch 7 — `bin/` wrapper cleanup

## 12.1 `bin/tool-runner`

Treat as the common execution primitive.

Validate:

- TTY forwarding;
- stdin forwarding;
- exit-code propagation;
- path conversion;
- service-running errors;
- working-directory selection.

## 12.2 `bin/php`

Preserve:

- explicit PHP version selection;
- default/highest configured runtime;
- normal CLI;
- current serve behavior where useful;
- mounted project;
- non-root execution.

Add tests for spaces in paths and Git safe-directory behavior.

## 12.3 `bin/composer`

Reduce duplicated PHP runtime selection where practical.

Preserve versioned Composer homes and project mount behavior.

## 12.4 DB wrappers

Files:

- `bin/pg`;
- `bin/my`;
- `bin/maria`;
- `bin/mongo`;
- `bin/redis-cli`;
- `bin/es`.

Requirements:

- use Compose/service names, not IPs;
- no assumptions about static subnets;
- credentials from environment/state;
- safe argument/file quoting;
- accurate exit codes;
- temporary dump/restore integration tests.

## 12.5 New AI wrappers

Prefer adding:

```text
bin/ai
bin/llm
```

or equivalent internal helpers invoked by `lds`.

Keep them thin.

They must not duplicate `askai`, `aiops` or `llm-ollama` logic.

---

# 13. Batch 8 — Compose/service hardening

## 13.1 `docker/compose/companion.yaml`

### `server-tools`

Use:

```text
${LDS_TOOLS_IMAGE:-infocyph/tools:0.23.2}
```

Preserve:

- project mount;
- SSL/root CA;
- generated Nginx/Apache/FPM/Composer state;
- Git config;
- scheduler state;
- SOPS state;
- optional SSH mount;
- logs;
- Docker socket.

Add AI environment from Section 8.

Use the Tools-owned healthcheck instead of inventing an external health command.

### `runner`

Use:

```text
${LDS_RUNNER_IMAGE:-infocyph/runner:0.5}
```

Preserve scheduler/log mounts.

Runner still has legitimate Docker access because its `pexe`/`dexe` and mounted jobs can execute commands in sibling containers.

Do not remove the socket until those use cases are intentionally redesigned.

### `mailpit`

Keep persistence and TLS.

Validate that its certificate paths are ready before requiring STARTTLS.

## 13.2 `docker/compose/http.yaml`

### Nginx

Use:

```text
${LDS_NGINX_IMAGE:-infocyph/nginx:0.4.1}
```

Preserve `80/443`, generated vhosts, certs, FPM sockets and logs.

### Apache

Use:

```text
${LDS_APACHE_IMAGE:-infocyph/apache:0.4.2}
```

Keep optional.

Use `unless-stopped` unless testing proves `always` is required.

## 13.3 `docker/compose/db.yaml`

### Redis

Keep persistent `/data`.

Review whether `redis/redis-stack-server:latest` remains desirable as a default or should use a compatibility-tested major/tag.

Do not change data format in the same release without migration guidance.

### PostgreSQL

Reconcile variable naming.

Current service sets:

```text
POSTGRES_DB=${POSTGRES_DATABASE:-postgres}
```

but the healthcheck references `POSTGRES_DB` through Compose interpolation rather than the resulting container env.

Use one canonical LocalDevStack variable and test it.

Validate the selected official Postgres image's current data directory contract before changing the volume mount.

### MySQL/MariaDB/MongoDB

Keep explicit local-dev credential variables.

Review moving `latest` defaults separately from the infrastructure-image migration.

Do not unexpectedly major-upgrade a user's database by changing defaults without documentation.

### Elasticsearch

Keep Elasticsearch/Kibana versions aligned.

Validate Filebeat compatibility with the same stack version.

## 13.4 `docker/compose/db-client.yaml`

Preserve:

- RedisInsight;
- CloudBeaver;
- Mongo Express;
- Kibana;
- Filebeat.

Improve startup dependencies only when meaningful:

- prefer service health/retry behavior;
- avoid dependency chains that deadlock optional profiles.

---

# 14. Docker socket trust boundary

Both Tools and Runner currently require powerful Docker access for real LocalDevStack functionality.

Do not remove the socket merely to make a security checklist look better.

Document the actual boundary:

```text
/var/run/docker.sock == effective host Docker control
```

## Tools reasons

Tools/admin functionality includes container/service inspection and management.

## Runner reasons

Runner helpers and user scheduler definitions may execute into sibling containers.

## Plan

1. inventory exact Docker commands used;
2. classify read/write/destructive operations;
3. retain required socket mounts;
4. ensure `llm-ollama` never receives the socket;
5. do not mount socket into ordinary databases/admin clients;
6. document that LocalDevStack is trusted local developer infrastructure.

A socket proxy is not required unless a future design demonstrates a useful permission reduction without breaking the product.

---

# 15. Docker config files

## `docker/conf/filebeat.yml`

Validate:

- current Elasticsearch/Filebeat version alignment;
- log paths;
- service DNS endpoint;
- no static IP reference.

## `docker/conf/openssl.cnf`

Validate current OpenSSL compatibility.

Do not weaken TLS globally just to support old clients unless a supported LocalDevStack flow requires it.

## `docker/conf/pg_hba.conf`

Remove any fixed-subnet assumptions.

Keep local Docker-network auth appropriately scoped.

## `docker/conf/postgresql.conf`

Currently optional/commented.

Decide one of:

- intentionally supported and tested; or
- clearly documented as inactive reference config.

Do not leave ambiguous pseudo-active config.

## `docker/conf/www-php.conf`

Validate generated FPM pool/socket integration.

## `docker/conf/www.conf`

Determine whether it is actively consumed.

If unused, mark/deprecate/remove only after search and runtime tests.

---

# 16. Generated/user-owned configuration

## `configuration/compose/`

Continue to hold generated user/project Compose fragments.

Add safe stale-artifact detection.

Never blindly delete files not known to LocalDevStack.

## `configuration/php/`

Preserve user-edited PHP configuration.

Updates must not overwrite user customizations.

## `configuration/scheduler/cron-jobs/`

Validate generated files before Runner consumes them.

Account for Windows CRLF.

## `configuration/scheduler/supervisor/`

Validate Supervisor syntax before stack restart where possible.

## SOPS directories

Paths:

- `configuration/sops/config`;
- `configuration/sops/global`;
- `configuration/sops/keys`.

Keep ignored/sensitive.

Ensure setup permissions remain restrictive.

## `configuration/ssh/`

Keep optional and read-only.

Never bake keys into images.

## `configuration/ssl/`

Reconcile actual host-visible state with named certificate volumes.

Documentation must identify which paths are authoritative.

---

# 17. Logs and rotation

Keep host-visible logs because they are useful in a workstation stack.

Validate compatibility with `runner:0.5` logrotate paths.

Review directory permissions.

Avoid broad `777` changes when a narrower cross-platform permission model works.

If permissive permissions are still required for Windows/macOS/Linux interoperability, document the local-development rationale.

Add a smoke that:

1. writes a test log;
2. Runner sees it;
3. rotation succeeds;
4. application continues writing.

---

# 18. Environment and precedence contract

Define one documented precedence order.

Recommended:

1. built-in product fallback;
2. tracked `docker/release.env`;
3. user `docker/.env`;
4. command-scoped explicit environment overrides.

Never shell-source untrusted dotenv content.

Separate classes of settings:

## Product/release

- infrastructure image refs;
- default feature compatibility versions.

## User stack

- selected profiles;
- DB credentials;
- ports;
- timezone;
- project directory;
- runtime selections.

## AI

- enabled/profile;
- runtime variant;
- model;
- optional host port;
- advanced Tools limits.

## Generated runtime

- PHP packages/extensions;
- Node globals/packages;
- UID/GID;
- generated project profiles.

`lds config` should be able to show effective non-secret configuration and redact secrets.

---

# 19. Cross-platform requirements

## Windows / Git Bash

Preserve `lds.bat`.

Tests must cover:

- Git executable discovery;
- Git Bash discovery;
- spaces in repo/project paths;
- `cygpath` conversion;
- Docker Desktop unavailable/running errors;
- working-directory preservation;
- CRLF-sensitive generated files.

## WSL

Avoid assuming Docker socket path/platform behavior that conflicts with Docker Desktop integration.

## macOS

Account for bind-mount UID behavior and browser trust-store commands.

## Linux

Preserve UID/GID mapping and native Docker behavior.

Avoid root-owned host project files after normal `lds` commands.

---

# 20. QoL improvements that belong in this phase

Implement only after core compatibility is stable.

## `lds status`

One concise product view:

- core services;
- selected profiles;
- health;
- domains;
- URLs;
- AI enabled/provider status.

## `lds urls`

Print known convenience URLs:

```text
https://admin.localhost
https://webmail.localhost
https://db.localhost
https://ri.localhost
https://me.localhost
https://kibana.localhost
https://llm-ollama.localhost   # when AI enabled
```

Only show profile-dependent URLs when relevant.

## `lds open <service>`

Open a known local service in the host browser using existing platform helpers.

## `lds doctor`

Check:

- Docker;
- Compose;
- expected networks;
- volume access;
- certificate state;
- port conflicts;
- image availability;
- selected service health;
- DNS/service resolution;
- optional AI provider status.

Doctor should diagnose, not mutate, unless the user explicitly chooses a fix action.

## `lds images`

Show effective infrastructure image compatibility versions.

This is useful when troubleshooting a mixed/overridden stack.

---

# 21. Documentation rewrite

LocalDevStack documentation should now describe the product users actually have.

## `README.md`

Lead with:

> Docker-based XAMPP alternative for PHP and Node.js local development.

First screen should explain:

- local domains;
- HTTPS;
- PHP/Node versions;
- databases;
- admin tools;
- mail;
- background workers;
- optional local AI.

Keep internal architecture below quickstart.

## `docs/concepts/architecture.rst`

Update responsibility map with the exact image split and optional AI provider.

## `docs/concepts/profiles-and-env.rst`

Document:

- release env vs user env;
- profile selection;
- runtime variant;
- AI profile;
- override precedence.

## `docs/concepts/storage-layout.rst`

Clearly separate:

- Docker named volumes;
- host configuration;
- host logs;
- project bind mounts;
- secrets;
- AI model volume.

## `docs/quickstart.rst`

Target beginner flow:

```text
lds setup init
lds setup permissions
lds setup profile
lds setup domain
lds up
```

Use the actual final command names after implementation.

## `docs/guides/domain-setup.rst`

Remove static-IP mental model.

Explain Docker DNS routing.

## `docs/guides/tls-and-certificates.rst`

Ensure `llm-ollama.localhost` and convenience-host certificate behavior is covered.

## New `docs/guides/local-ai.rst`

Cover:

- enabling AI;
- CPU/NVIDIA/AMD;
- `https://llm-ollama.localhost`;
- `lds ai`;
- `lds llm`;
- model persistence;
- selecting a different model;
- direct host port opt-in;
- privacy boundaries;
- optional workspace access;
- Graphify connection.

## Existing SOPS/notification docs

Revalidate against `tools:0.23.2`.

---

# 22. Migration/backward compatibility

The first integrated LocalDevStack release must handle existing installations deliberately.

## Existing databases/volumes

Do not rename volumes in this release.

## Existing Nginx vhost volume

Older volumes may contain upstream `default.conf` artifacts.

Use the Nginx 0.4.1 documented cleanup/migration behavior and test an upgraded volume.

## Existing fixed networks

Compose recreation may replace old fixed networks.

Document that containers may be recreated while named-volume data remains.

Do not run destructive `docker compose down -v` during migration.

## Existing `docker/.env`

Preserve user values.

New release defaults must not overwrite it.

## Existing generated runtime images

Detect/rebuild only when relevant inputs changed.

## Existing users without AI

Their stack should not pull `llm-ollama`, create the model volume or consume GPU resources unless AI is selected.

---

# 23. Release-readiness matrix

A LocalDevStack release candidate is not ready until these pass.

## Core

- clean install;
- existing-install upgrade;
- `lds help`;
- setup init;
- setup permissions;
- setup profiles;
- domain create/delete;
- trusted HTTPS;
- Nginx core routing;
- Tools admin;
- Mailpit;
- Runner.

## PHP

At least:

- one current PHP runtime build;
- Composer;
- FPM through Nginx;
- FPM through Apache path if supported;
- custom extension/package fixture.

## Node

At least:

- one current Node runtime build;
- npm/npx;
- Node proxy;
- WebSocket/HMR fixture.

## Databases

Smoke:

- PostgreSQL;
- MySQL;
- MariaDB;
- MongoDB;
- Redis;
- Elasticsearch.

Include admin clients where practical.

## AI

With fake provider on normal CI:

- Tools provider;
- `askai`;
- `aiops`;
- Nginx LLM route;
- streaming.

With real provider on manual/release gate when feasible:

- `infocyph/llm-ollama:latest`;
- baked `qwen3.5:9b`;
- persistent model volume;
- Tools generation;
- Nginx `llm-ollama.localhost`.

## Platforms

At minimum:

- Linux full integration;
- Windows bridge/path validation;
- explicit documentation/manual verification for macOS/WSL if CI environment does not support full Docker Desktop tests.

---

# 24. Must-ship vs follow-up

## Must ship

- product CI;
- explicit published infrastructure versions;
- static-IP removal;
- core Compose validation;
- AI profile/provider integration;
- persistent LLM model volume;
- Tools AI env wiring;
- PHP/Node Scriptomatic `main` migration;
- safe `lds` modularization of touched areas;
- DB health/env correctness fixes discovered by CI;
- updated docs;
- release/upgrade smoke.

## Follow-up allowed

These do not block the LocalDevStack integration release unless implementation reveals a direct dependency:

- multi-instance container/volume namespacing;
- automatic dependency-update PRs;
- Docker socket proxy;
- Graphify installation;
- browser AI UI beyond Tools admin panel;
- conservative GPU/runtime detection with explicit override;
- automatic model downloads beyond the baked model;
- production-hardening changes unrelated to local development;
- rewriting the CLI in another language.

---

# 25. Definition of completion

This LocalDevStack phase is complete when all of the following are true:

1. LocalDevStack consumes the published compatibility matrix by explicit default.
2. No core LocalDevStack service requires a hard-coded `172.28/29/30` address.
3. `lds` still presents the existing public workflow while internals are better separated and tested.
4. PHP and Node remain locally customizable runtime builds.
5. Scriptomatic consumption no longer uses stale `master` references.
6. Tools, Runner, Nginx and Apache integrate using their published health/runtime contracts.
7. Local domains/TLS work through service-name routing.
8. Databases and admin clients work through Docker DNS.
9. Mailpit remains persistent and TLS-capable.
10. Runner cron/Supervisor/logrotate workflows still work.
11. AI can be omitted completely with no degradation to the default product.
12. When AI is enabled, exactly one provider is active: FastFlow for supported XDNA2 NPU, otherwise Ollama.
13. The active provider persists its own model store and owns the common `llm:11434` identity; `https://llm.localhost` and loopback-only `http://127.0.0.1:11434` work through Nginx.
14. Tools `askai` / `aiops`, Graphify, and the provider CLIs use the common OpenAI-compatible LLM route; provider-specific native routes remain diagnostic/low-level only.
15. No LocalDevStack component embeds a second model runtime or starts both `llm-fastflow` and `llm-ollama` for one stack.
16. No AI component auto-executes model-generated commands.
17. Existing user volumes and env overrides survive upgrade.
18. Docker socket exposure is documented and limited to components that actually require it.
19. Product docs match the implemented storage, network, version and AI behavior.
20. A clean supported workstation can go from clone/setup to a working HTTPS PHP or Node local domain using the documented flow.

---

# 26. First implementation checkpoint

Before any broad refactor, the first implementation PR/batch should contain only:

1. permanent LocalDevStack CI foundation;
2. tracked compatibility image defaults;
3. Compose references switched from infrastructure `:latest` to those defaults;
4. characterization tests around current `lds`;
5. no static-IP removal yet;
6. no `lds` modularization yet.

Once that is green, proceed to the networking migration.

This gives every later change a reliable regression boundary.


---

# Appendix — User-directed Alpine-first moving-tag policy override (2026-09-18)

This section is an explicit product-direction override and supersedes earlier image-pinning recommendations in this plan wherever they conflict.

## Image default policy

Prefer the moving Alpine variant when the same image family publishes/supports one; otherwise use its normal moving latest tag.

LocalDevStack release defaults:

```text
LDS_TOOLS_IMAGE=infocyph/tools:latest
LDS_RUNNER_IMAGE=infocyph/runner:latest
LDS_NGINX_IMAGE=infocyph/nginx:latest
LDS_APACHE_IMAGE=infocyph/apache:latest
```

Other runtime defaults follow the same rule. PostgreSQL uses `postgres:alpine`; MySQL, MariaDB, MongoDB, Redis Stack/Redis Insight, CloudBeaver, Mongo Express and Mailpit use their normal moving latest tags because the selected image family does not provide a suitable moving Alpine alias for this stack.

## Elastic current-release exception

The Elastic image set used by LocalDevStack does not expose a usable moving `latest`
alias. Elasticsearch, Kibana and Filebeat therefore share one
`ELASTICSEARCH_VERSION` selector and default to the newest stable release verified by
the compatibility gate.

Current default:

```text
9.5.4
```

Advance this single selector when Elastic publishes a newer stable release; all three
services and their contract tests must move together.

## Override precedence

User values in `docker/.env` and command-scoped shell environment still override these defaults.

The Alpine-first moving-tag policy changes default image selection only; it does not weaken:

- profile isolation;
- AI trust boundaries;
- dynamic networking;
- persistent-volume behavior;
- loopback-only optional Ollama host exposure;
- compatibility/contract testing.


## Runtime version-selection invariant

The Alpine-first moving-image policy does **not** replace the existing PHP/Node runtime version selector.

LocalDevStack must preserve the published Tools runtime-selection contract:

- `mkhost` reads `/etc/share/runtime-versions.json`;
- PHP runtime selection remains version-specific;
- Node runtime selection remains version/tag-specific;
- the selected PHP value remains the `PHP_VERSION` build arg and `localdevstack-php:<version>` image identity;
- the selected Node value remains the `NODE_VERSION` build arg and `localdevstack-node:<version>` image identity;
- selected PHP and Node bases continue to use their Alpine variants;
- moving Alpine/latest defaults apply only when the user has not selected/persisted a more specific version;
- explicit user-selected versions always win.

Batch 6 must not collapse these selectors into a single global PHP or Node version.


---

# Implementation completion record — 2026-09-18

All planned LocalDevStack integration batches are implemented on branch `plan/docker-ecosystem-bottom-up`.

## Completed batches

1. **Batch 1 — CI + characterization**
   - permanent CI foundation;
   - CLI/env/runtime/network characterization;
   - Windows bridge coverage;
   - published-image checks.

2. **Batch 2 — image/default policy**
   - tracked `docker/release.env`;
   - deterministic fallback/release/user/shell precedence;
   - user-directed Alpine-first moving image policy;
   - explicit Elastic aligned-version exception.

3. **Batch 3 — networking/DNS migration**
   - static `172.28/29/30` addresses removed;
   - Docker DNS/service-name routing;
   - deterministic legacy-network migration;
   - `vpn-fix` deprecated.

4. **Batch 4 — optional AI integration**
   - optional `ai` profile;
   - mutually-exclusive FastFlow/Ollama provider services behind common `llm:11434`;
   - persistent `LLMModels` and `LLMFastFlowModels`;
   - XDNA2 NPU / NVIDIA / AMD ROCm / CPU runtime modes with automatic detection;
   - `https://llm.localhost` plus provider-specific diagnostic routes;
   - Nginx-owned loopback-only common native API port;
   - provider-neutral Tools consumer wiring;
   - `lds ai` / `lds llm` separation;
   - common OpenAI-compatible fake-provider integration test.

5. **Batch 5 — profiles/catalog/runtime defaults**
   - canonical host service catalog;
   - profile setup driven from catalog metadata;
   - AI setup fields;
   - published Tools profile-drift checks;
   - interactive runtime version selection preserved.

6. **Batch 6 — PHP/Node runtime modernization**
   - Scriptomatic `main` / full-SHA contract;
   - bounded download + non-empty/syntax validation;
   - selected `PHP_VERSION` / `NODE_VERSION` retained inside build stage;
   - Alpine runtime bases retained;
   - rebuild cache preserved with `--pull`.

7. **Batch 7 — CLI modularization + wrapper cleanup**
   - `lds` split into focused `lib/*.sh` modules;
   - Windows wrapper Docker preflight boundary corrected;
   - wrapper/runtime/database contracts added;
   - fixed-IP assumptions removed from wrappers.

8. **Batch 8 — Compose/service hardening**
   - health-gated service dependencies;
   - credential-free database readiness checks;
   - Docker socket limited to Tools/Runner;
   - inactive PostgreSQL tuning config made explicit;
   - unused legacy FPM config removed;
   - Runner health/logrotate contract validated;
   - public TLS export bridge corrected to `configuration/ssl/rootCA.pem` with legacy fallback.

9. **Batch 9 — permissions/QoL/docs/release gate**
   - broad `chmod -R 777` removed;
   - SSH/SOPS key directories hardened;
   - `lds urls`, `lds images`, redacted grouped `lds config`, and diagnostic-only `lds doctor`;
   - Sphinx user documentation rewritten for the implemented architecture;
   - dedicated local-AI guide;
   - docs contract + warning-as-error Sphinx CI;
   - release-gate script contains all Linux/runtime/AI/published-image contracts.

## Final policy clarifications

- Prefer a moving Alpine variant when an image family provides a suitable one; otherwise use its normal moving latest alias.
- PostgreSQL defaults to `postgres:alpine`.
- Tools, Runner, Nginx and Apache consume their published `:latest` aliases.
- Exactly one LLM provider is active: XDNA2 NPU uses `infocyph/llm-fastflow:latest`; CPU/NVIDIA use `infocyph/llm-ollama:latest`; AMD/ROCm uses `infocyph/llm-ollama:amd-latest`.
- Elasticsearch, Kibana and Filebeat share the `ELASTICSEARCH_VERSION` selector and currently default to stable `9.5.4`, because the required Elastic image set has no usable moving `latest` alias.
- PHP/Node runtime selection remains user-driven and version-specific.
- Existing named volumes and container names remain intentionally stable for this release.

## Non-blocking follow-ups retained from the plan

These remain future work rather than release blockers:

- multi-instance container/volume namespacing;
- automatic dependency-update PRs;
- Docker socket proxy if it can reduce privilege without breaking supported workflows;
- Graphify installation/management;
- additional browser AI UI;
- automatic model downloads beyond the provider defaults.


---

# Post-implementation cross-image audit — 2026-09-18

Audit window: approximately **2026-09-16 13:53 Asia/Dhaka through 2026-09-18**.

Compared LocalDevStack against the current related releases/main contracts:

- Tools **0.25**
- Runner **0.5**
- Nginx **0.6**
- Apache **0.4.2**
- LLM-FastFlow **0.01.2**
- LLM-Ollama **0.05**
- Toolset **2.0**
- Scriptomatic current `main`

The final published/check runs for those release heads are successful.

## Feature-parity result

No legacy LocalDevStack command/service/storage feature was removed:

- all **60** old public/support `lds` functions still exist after modularization;
- all **9** old `bin/*` wrappers remain;
- all **16** old Compose services remain; the current graph has **18** services after adding the two mutually-exclusive LLM provider definitions;
- all **19** old named volumes remain; the current graph has **22** named volumes after adding the two provider stores and Tools durable state.

New runtime additions are additive:

- `llm-ollama` and `llm-fastflow` provider definitions (mutually exclusive at runtime);
- `LLMModels` and `LLMFastFlowModels`;
- `ToolsState`;
- AI/QoL/diagnostic commands.

## Cross-image issues found and corrected

### Tools durable state

Tools 0.23.2 owns mutable state under `/etc/share/state` for host-manager/env-store,
profile/runtime state, monitor history and alert acknowledgement state.

LocalDevStack now persists that directory through the global named volume:

```text
ToolsState -> /etc/share/state
```

This prevents Tools control-plane state from disappearing when `server-tools` is recreated.

### Root CA export bridge

Tools exports the public CA to:

```text
configuration/ssl/rootCA.pem
```

Unix and Windows LocalDevStack certificate-install paths now use that current export,
with `configuration/rootCA/rootCA.pem` retained only as a legacy read fallback.

### TLS export permissions

Tools deliberately exports opt-in user P12 material with mode `0600`.
`lds setup permissions` now preserves restrictive modes for P12/PFX/key artifacts
instead of widening all files under `configuration/ssl` to group-readable mode.

### Tools profile visibility

`COMPOSE_PROFILES` is now passed into `server-tools` so the current Tools status/Admin
diagnostic layer can report LocalDevStack's active profile selection.

### Moving-image drift

Because LocalDevStack intentionally follows moving image aliases, the compatibility
workflow now runs weekly even when LocalDevStack source has not changed.

A scheduled/manual runtime-build smoke also builds the current selected PHP and Node
versions from Tools' runtime catalog against Scriptomatic `main` and verifies the
runtime plus Toolset helper surface.

## Apache compatibility decision

Apache 0.4.2 is architecturally an optional backend, and the LocalDevStack CLI already
tracks `APACHE_ACTIVE` / `APACHE_DELETE` state.

However, the new Tools Admin Panel Host Manager can create/edit Apache hosts directly
and currently does not control LocalDevStack's host-side `COMPOSE_PROFILES` lifecycle.

Therefore Apache remains an always-created compatibility service in this release.
Making the container profile-only before adding a proper Admin Panel↔LocalDevStack
profile bridge would regress Admin Panel-created Apache hosts.

This is a non-blocking follow-up, not a release defect.

## LLM provider capability boundaries

The published FastFlow and Ollama provider contracts used by this integration are
**linux/amd64** AI runtimes. LocalDevStack remains usable with the `ai` profile disabled
on unsupported platforms.

LocalDevStack intentionally does not mount a repository/workspace into either provider
by default. Direct model/API/chat/stdin workflows are supported through the active
provider, while repository-aware analysis remains available through the Tools consumer
layer (`lds ai review`, `repo-review`) and explicit provider workspace features when a
user intentionally enables them.

Exactly one provider runs for a stack. FastFlow owns supported XDNA2 NPU execution;
Ollama owns NVIDIA, AMD ROCm and CPU execution.

## Lower-layer compatibility notes

- Tools' own feature-parity contract preserves its pre-hardening CLI/Admin surface.
- Tools' template ABI explicitly targets Nginx 0.4.1, Apache 0.4.2 and Runner 0.5.
- Runner 0.5 has a LocalDevStack-shaped integration smoke.
- Nginx routes use lazy Docker DNS and do not require optional profile services to exist
  at Nginx startup.
- Scriptomatic still installs the same PHP/Node runtime Toolset helper surface
  (`gitx` + `chromacat`); acquisition changed to the checksum-verified latest-stable
  Toolset release installer.
- The PHP template's historical `GID:-root` fallback predates this audit window.
  Supported LocalDevStack setup writes a numeric UID/GID before runtime generation, so
  it is not a current LocalDevStack release blocker.

## Readiness conclusion

After the corrections above and the final 2026-09-20 provider integration, there is no
identified legacy feature loss or current cross-image release blocker. Tools 0.25,
Nginx 0.6, FastFlow 0.01.2 and Ollama 0.05 are validated by the current compatibility
gate. The remaining items are explicit optional/future capability work rather than
regressions.


---

# Historical interim simplification — fixed infrastructure images

This section records the pre-FastFlow simplification that established fixed infrastructure
images and ephemeral GPU augmentation. Its Ollama-only provider statements are superseded
by the **Final AI provider architecture override — 2026-09-20** below.

## Fixed infrastructure images

Tools, Runner, Nginx, and Apache have no LocalDevStack runtime image variants. Their image names are therefore declared directly in Compose:

```text
infocyph/tools:latest
infocyph/runner:latest
infocyph/nginx:latest
infocyph/apache:latest
```

Do not add `LDS_TOOLS_IMAGE`, `LDS_RUNNER_IMAGE`, `LDS_NGINX_IMAGE`, or `LDS_APACHE_IMAGE` indirection. `docker/release.env` is reserved for release/build defaults that genuinely vary, currently including `SCRIPTOMATIC_REF`.

## Provider-service evolution

The earlier implementation temporarily tracked only `llm-ollama` in
`docker/compose/companion.yaml`, with CPU/NVIDIA mapped to `latest` and AMD/ROCm to
`amd-latest`. That intermediate state established the generated NVIDIA/ROCm hardware
augmentation and Nginx-owned loopback publication.

The final implementation now tracks both provider definitions in the same companion file
and enables exactly one through generated profile selection:

```text
npu     -> llm-fastflow / infocyph/llm-fastflow:latest
nvidia  -> llm-ollama  / infocyph/llm-ollama:latest
amd     -> llm-ollama  / infocyph/llm-ollama:amd-latest
cpu     -> llm-ollama  / infocyph/llm-ollama:latest
```

NVIDIA/ROCm hardware augmentation remains ephemeral; FastFlow's XDNA2
`/dev/accel/accel0` + memlock contract is part of its tracked service definition.
Nginx continues to own loopback-only `127.0.0.1:11434`, now proxying the common
`llm:11434` alias.

---

# Final AI provider architecture override — 2026-09-20

This section supersedes every earlier Ollama-only or single-provider-service statement
in this plan where they conflict with the final LocalDevStack implementation.

## Provider selection

LocalDevStack tracks two provider service definitions in `docker/compose/companion.yaml`,
but enables exactly one of them for the `ai` profile:

```text
supported XDNA2 NPU -> llm-fastflow -> infocyph/llm-fastflow:latest
NVIDIA GPU          -> llm-ollama  -> infocyph/llm-ollama:latest
AMD ROCm GPU        -> llm-ollama  -> infocyph/llm-ollama:amd-latest
CPU fallback        -> llm-ollama  -> infocyph/llm-ollama:latest
```

`llm-fastflow` and `llm-ollama` are mutually exclusive. They must not be active at the
same time for one LocalDevStack runtime.

## Common LLM identity

The selected provider owns the common Docker network alias and normalized internal port:

```text
llm:11434
```

Provider-neutral consumers use:

```text
LDS_AI_PROVIDER=llm
LDS_AI_URL=http://llm:11434
https://llm.localhost/v1
http://127.0.0.1:11434/v1
```

Provider-specific `llm-ollama.localhost` and `llm-fastflow.localhost` routes are
diagnostic/native identities only. Nginx owns the loopback publication and proxies it
to the common `llm` alias.

## Model defaults

The default model follows the runtime:

```text
FastFlow / NPU -> qwen3.5:9b
Ollama         -> qwen3.5:9b
```

Setup leaves `LDS_AI_MODEL` blank by default so the correct provider default can apply.
An explicit user value remains authoritative for the active provider.

## Runtime selection

Automatic detection order is XDNA2 NPU, NVIDIA, AMD ROCm, CPU. The explicit selector is:

```text
lds llm runtime auto|npu|nvidia|amd|cpu
```

FastFlow's XDNA2 device/memlock contract is tracked in its service definition. NVIDIA
and ROCm Ollama hardware settings remain temporary Compose augmentation.

## Persistence

```text
LLMModels         -> Ollama /root/.ollama
LLMFastFlowModels -> FastFlow /models
```

Neither provider receives a Docker socket or project/repository bind mount by default.

## Completion impact

The release-readiness AI matrix must validate both provider selections, the common
OpenAI-compatible `/v1` route, published `llm-fastflow:latest`, published Ollama images,
and the rule that only one provider service is present in the effective Compose graph.
