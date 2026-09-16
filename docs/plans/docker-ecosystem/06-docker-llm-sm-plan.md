# docker-llm-sm — File-by-File Compatibility + Integration Plan

## Role

`infocyph/docker-llm-sm` is the optional local-AI service for the LocalDevStack ecosystem. It is already published and already uses the newer single-repository tag model:

- standard CPU/NVIDIA: `latest`, `<release>`
- AMD ROCm: `amd-latest`, `amd-<release>`

This plan is intentionally conservative. The image should remain independently useful outside LocalDevStack.

## Invariants

- LocalDevStack integration must remain optional.
- The default model remains replaceable by the user.
- `/root/.ollama` must be persisted by the consumer/orchestrator.
- CLI commands bundled in the image remain available; users do not install/remove the CLI separately.
- CPU/NVIDIA and AMD ROCm remain separate tag families within the same registry repository.
- LocalDevStack must not rebuild `docker-llm-sm` locally.
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

### `scripts/llm-sm`

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

LocalDevStack should add an optional `llm`/`ai` profile that consumes the published image.

Suggested variables:

- `LLM_SM_IMAGE=infocyph/llm-sm:latest` or pinned release;
- `LLM_SM_MODEL=<model>` only when overriding image default/use selection;
- `LLM_SM_VOLUME=<named-volume>`;
- optional GPU mode selection: CPU/NVIDIA standard tag vs AMD tag;
- optional workspace mount path.

Persistence:

- mount named volume to `/root/.ollama`;
- preserve user-pulled models across container recreation/upgrades.

Workspace:

- optional `${PROJECT_DIR}` or selected project path -> `/workspace`;
- working directory `/workspace` where repo-aware commands are desired;
- mount must be declared at container creation time;
- do not require workspace mount for normal inference/API use.

Networking:

- join the appropriate LocalDevStack internal network by service name;
- expose `11434` to host only if local host tools (Graphify/editor integrations/etc.) need it;
- if exposed, default host binding should remain loopback-oriented for a local dev stack;
- other containers should use service DNS, e.g. `http://llm-sm:11434`.

Graphify/client integration:

- point client to Ollama/OpenAI-compatible endpoint exposed by `llm-sm`;
- keep `qwen2.5:3b` usable as the default small model;
- allow users to pull/select larger models without changing LocalDevStack image definitions.

## Acceptance Criteria

1. Existing published `docker-llm-sm` behavior remains standalone and stable.
2. LocalDevStack can enable it without building locally.
3. Standard and AMD tags are selectable.
4. Named volume persists pulled models across container recreation.
5. Other LocalDevStack containers can reach Ollama by service DNS.
6. Host clients can reach it through an explicitly configured loopback port when enabled.
7. `docker exec <container> llm-sm ...` works under LocalDevStack.
8. Mounted project repo supports `llm-sm ai-commit` without host installation.
9. No Graphify/LocalDevStack-specific package is added to the image solely for integration.
