# docker-llm-ollama — File-by-File Compatibility + Integration Plan

## Role

`infocyph/docker-llm-ollama` is the optional local-AI service for the LocalDevStack ecosystem. It is already published and already uses the newer single-repository tag model:

- standard CPU/NVIDIA: `latest`, `<release>`
- AMD ROCm: `amd-latest`, `amd-<release>`

This plan is intentionally conservative. The image should remain independently useful outside LocalDevStack.

## Invariants

- LocalDevStack integration must remain optional.
- The default model remains replaceable by the user.
- `/root/.ollama` must be persisted by the consumer/orchestrator.
- CLI commands bundled in the image remain available; users do not install/remove the CLI separately.
- CPU/NVIDIA and AMD ROCm remain separate tag families within the same registry repository.
- LocalDevStack must not rebuild `docker-llm-ollama` locally.
- Graphify or other AI clients consume the Ollama endpoint; they are not baked into this image merely because they can use it.

## Existing Files

### `.github/workflows/docker.publish.yml`

Treat as the reference workflow for the older Docker repos.

Plan:

- keep single-repository standard/AMD tag families;
- keep release tags immutable;
- keep scheduled builds refreshing moving `latest`/`amd-latest` tags only;
- retain separate cache scopes/variant builds;
- retain Docker Hub + GHCR publication and attestations;
- only change if a later ecosystem-wide workflow improvement (SBOM/scanning/action major) is adopted consistently.

### `.github/workflows/cli.check.yml`

Keep as the CLI/Compose validation baseline.

Potential additions only if needed by integration:

- verify image-bundled CLI layout;
- verify persistent `/root/.ollama` contract;
- verify repo-aware command behavior against `/workspace` mount;
- verify no LocalDevStack-specific dependency enters the image.

### `Dockerfile`

Plan:

- keep Ollama-based build and baked default model architecture;
- keep build-time model pull separated from runtime cloud-disable policy;
- preserve fixed in-image CLI installation;
- preserve healthcheck;
- do not add LocalDevStack-specific orchestration scripts;
- if ecosystem image metadata conventions are standardized, align labels without changing runtime behavior.

### `.env.example`

Keep standalone variables for image users.

LocalDevStack should define its own integration variables rather than requiring users to copy this file.

### `compose.yml`

Keep as standalone CPU/default example.

Do not alter it merely to match LocalDevStack’s profile layout.

### `examples/compose/cpu.yml`

Keep published-image/persistent-volume CPU example.

### `examples/compose/nvidia.yml`

Keep published-image/persistent-volume NVIDIA example and GPU request semantics.

### `examples/compose/amd.yml`

Keep `amd-latest`/ROCm example and `/dev/kfd` + `/dev/dri` device requirements.

### `scripts/llm-ollama`

Keep as fixed dispatcher installed in the image.

Integration requirement:

- commands invoked through `docker exec` must work regardless of LocalDevStack container name chosen by profile;
- no host installer/uninstaller lifecycle.

### `scripts/lib/core.sh`

- keep model/API/config helpers generic;
- support environment overrides LocalDevStack can pass;
- no knowledge of LocalDevStack networks/profile names.

### `scripts/lib/ollama.sh`

- preserve internal Ollama CLI/API helpers;
- ensure endpoint assumptions work inside the same container.

### `scripts/lib/commit.sh`

- preserve Git workspace/safe-directory handling for mounted repositories;
- keep staged-diff behavior self-contained.

### Command files

Files include:

- `commands/ai-commit.sh`
- `api.sh`
- `ask.sh`
- `chat.sh`
- `code.sh`
- `help.sh`
- `json.sh`
- `logs.sh`
- `models.sh`
- `ollama.sh`
- `prompt.sh`
- `ps.sh`
- `pull.sh`
- `restart.sh`
- `review.sh`
- `rm.sh`
- `run.sh`
- `show.sh`
- `start.sh`
- `status.sh`
- `stop.sh`
- `unload.sh`
- `version.sh`

Plan for all command files:

- keep image-local responsibilities clear;
- commands that manage models/prompts/API remain first-class;
- any start/stop/restart/log/status command must reflect the actual in-container Ollama process model and not imply Docker host lifecycle control;
- preserve exit codes suitable for `docker exec`;
- keep `ai-commit` able to use a mounted `/workspace` Git repository;
- keep stdin fallback where already supported;
- do not add LocalDevStack wrappers into this repository.

### `scripts/prompts/ai-commit.txt`

- keep bundled/self-contained prompt;
- version prompt changes with image releases;
- LocalDevStack must not override it by default.

### `README.md`

Keep standalone documentation authoritative for direct image users.

Add LocalDevStack mention only after integration exists, and only as a short interoperability note/link.

### `.dockerignore`, `.gitignore`, `.gitattributes`, `LICENSE`

No LocalDevStack-driven change expected.

## LocalDevStack Integration Contract

This lower-layer plan is implemented through the authoritative LocalDevStack integration
plan in `07-localdevstack-integration-plan.md`.

LocalDevStack consumes the published provider through the optional `ai` profile. It does
not rebuild `docker-llm-ollama` locally and does not consume this repository's standalone
Compose files.

Current LocalDevStack controls:

- `LDS_AI_MODEL` selects the shared Tools/provider default model and is forwarded as
  `LLM_OLLAMA_MODEL`;
- `LDS_AI_RUNTIME` selects `cpu`, `nvidia`, or `amd` when explicitly configured;
- `LDS_LLM_ARCH` is derived from the effective runtime (`latest` for CPU/NVIDIA,
  `amd-latest` for AMD/ROCm);
- provider input/PDF/Ollama tuning values are forwarded from LocalDevStack
  `docker/.env`;
- host access is owned by LocalDevStack Nginx, not by the provider container.

Compose ownership:

- one tracked `llm-ollama` service in `docker/compose/companion.yaml`;
- no tracked `ai.yaml`, `ai-nvidia.yaml`, `ai-amd.yaml`, or
  `ai-host-port.yaml`;
- NVIDIA and AMD/ROCm additions are generated temporarily under
  `docker/.runtime/` by `lds`;
- Nginx publishes the fixed loopback-only native endpoint on host port `11434`.

Persistence:

- LocalDevStack's `LLMModels` named volume mounts at `/root/.ollama`;
- user-pulled models survive container recreation/upgrades.

Workspace:

- LocalDevStack intentionally does not mount a project/repository into `llm-ollama` by
  default;
- repository-aware analysis normally uses the Tools consumer layer;
- provider stdin flows remain available without weakening the default trust boundary.

Networking:

- internal consumers use `http://llm-ollama:11434`;
- Nginx exposes `https://llm-ollama.localhost`;
- Nginx also exposes `http://llm-ollama.localhost:11434` through a fixed
  loopback-only host bind;
- the provider container itself has no published host port.

User/provider commands are invoked through `lds llm ...`, not a bare
`docker compose exec` from the LocalDevStack repository root.

## Acceptance Criteria

1. Existing published `docker-llm-ollama` behavior remains standalone and stable.
2. LocalDevStack can enable it without building locally.
3. Standard and AMD tags are selectable.
4. Named volume persists pulled models across container recreation.
5. Other LocalDevStack containers can reach Ollama by service DNS.
6. Host clients can reach it through Nginx at the fixed loopback-only native Ollama endpoint.
7. `lds llm ...` delegates to the bundled provider CLI through LocalDevStack's Compose wrapper.
8. No project/repository bind mount is required for normal provider operation.
9. No Graphify/LocalDevStack-specific package is added to the image solely for integration.
