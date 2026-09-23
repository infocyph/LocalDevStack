Local AI
========

LocalDevStack can enable one local LLM provider through the optional ``ai`` profile.

Provider Selection
------------------

Exactly one provider service is active for a LocalDevStack runtime:

.. code-block:: text

   supported AMD XDNA2 NPU -> llm-fastflow -> infocyph/llm-fastflow:latest
   NVIDIA GPU              -> llm-ollama  -> infocyph/llm-ollama:latest
   AMD ROCm GPU             -> llm-ollama  -> infocyph/llm-ollama:amd-latest
   otherwise                -> llm-ollama  -> infocyph/llm-ollama:latest

``llm-fastflow`` and ``llm-ollama`` are mutually exclusive. They are not designed to run
simultaneously for one stack. The selected service owns the common Docker-network alias
``llm`` and the normalized internal LLM port ``11434``.

Enable and Inspect AI
---------------------

.. code-block:: bash

   lds profiles add ai
   lds start
   lds llm runtime
   lds llm provider
   lds images
   lds doctor

Provider-neutral clients should use:

.. code-block:: text

   Docker network: http://llm:11434/v1
   HTTPS:          https://llm.localhost/v1
   host loopback:  http://127.0.0.1:11434/v1

Provider-specific diagnostic/native routes remain available:

.. code-block:: text

   https://llm-ollama.localhost
   https://llm-fastflow.localhost

The inactive provider-specific route normally returns ``502`` because its service is absent.

Runtime Detection
-----------------

Automatic detection prefers:

1. a FastFlow-supported XDNA2 NPU;
2. usable NVIDIA via ``nvidia-smi``;
3. AMD ROCm when both ``/dev/kfd`` and ``/dev/dri`` exist;
4. CPU.

Override detection explicitly when needed:

.. code-block:: bash

   lds llm runtime auto
   lds llm runtime npu
   lds llm runtime nvidia
   lds llm runtime amd
   lds llm runtime cpu

``auto`` clears the explicit runtime and returns to host detection.

FastFlow / NPU
--------------

FastFlow is selected only for ``npu``. The host must provide a supported XDNA2 NPU at
``/dev/accel/accel0`` with the compatible ``amdxdna`` host-driver/firmware contract.

LocalDevStack configures:

.. code-block:: text

   image: infocyph/llm-fastflow:latest
   LLM_FASTFLOW_MODEL=<effective model>
   FLM_MODEL_PATH=/models
   FLM_SERVE_PORT=11434
   FLM_HOST=0.0.0.0
   FLM_CORS=0
   FLM_DISABLE_UPDATE_CHECK=1

The container receives the NPU device plus unlimited memlock. It does not install the
kernel driver, require privileged mode, or receive the Docker socket.

FastFlow model data persists in ``LLMFastFlowModels`` mounted at ``/models``.

Ollama
------

Ollama owns CPU, NVIDIA and AMD ROCm paths:

.. code-block:: text

   cpu     -> infocyph/llm-ollama:latest
   nvidia  -> infocyph/llm-ollama:latest
   amd     -> infocyph/llm-ollama:amd-latest

NVIDIA receives an ephemeral ``gpus: all`` Compose augmentation. AMD receives ephemeral
``/dev/kfd`` and ``/dev/dri`` mappings. On an AMD CPU with the AMD runtime, the derived
``LDS_AI_IGPU_ENABLE`` value may be ``1`` and is forwarded as ``OLLAMA_IGPU_ENABLE``.

Ollama state persists in ``LLMModels`` mounted at ``/root/.ollama``.

Model Defaults
--------------

Both provider families use the same default model:

.. code-block:: text

   FastFlow / NPU -> qwen3.5:9b
   Ollama         -> qwen3.5:9b

New setup leaves ``LDS_AI_MODEL`` blank so the selected provider default can apply.
An explicit ``LDS_AI_MODEL`` in ``docker/.env`` overrides whichever provider is active.
Keep ``LDS_AI_MODEL`` blank when you want the common ``qwen3.5:9b`` default to follow
automatic runtime switching; set it only for an intentional override.

Thinking Control
----------------

Thinking uses one provider-neutral LocalDevStack switch:

.. code-block:: bash

   lds llm think          # prints auto/on/off
   lds llm think auto     # provider/model default
   lds llm think on
   lds llm think off

The persisted setting is ``LDS_AI_THINK``, which LocalDevStack maps to the common
provider variable ``LLM_THINK`` for both Ollama and FastFlow. Normal developer
commands inherit that setting. Strict structured-output paths such as ``json`` and
``lds graphify`` force thinking off so reasoning cannot displace the required JSON
payload.

Provider CLI
------------

Always invoke provider commands through ``lds llm``:

.. code-block:: bash

   lds llm models
   lds llm pull <model>
   lds llm run <model>
   lds llm ask "Explain dependency injection briefly"
   lds llm chat
   lds llm prompt "Summarize this"
   lds llm code "Implement this function"
   lds llm review file.php
   lds llm json "Return one JSON object"
   lds llm api /v1/models
   lds llm version

Provider-specific low-level commands are guarded:

.. code-block:: text

   Ollama-only:   ps, show, unload, ollama
   FastFlow-only: validate, check, flm

LocalDevStack refuses those commands when the other provider is active.

Tools Consumer
--------------

``server-tools`` receives ``LDS_AI_RUNTIME`` as the routing source of truth.
It resolves the active provider directly on the Docker network:

.. code-block:: text

   npu             -> http://llm-fastflow:11434/v1
   cpu|nvidia|amd  -> http://llm-ollama:11434/v1

``LDS_AI_MODEL`` remains the optional model override. Tools does not route through the
user-facing ``llm.localhost`` hostname.

Therefore ``lds ai`` commands remain provider-neutral at the command surface:

.. code-block:: bash

   lds ai status
   lds ai ask "Explain this error"
   lds ai troubleshoot
   lds ai review
   lds ai repo-review

Provider Options
----------------

Ollama-specific settings remain available through ``docker/.env``:

.. code-block:: text

   LLM_OLLAMA_SYSTEM=
   LLM_OLLAMA_INPUT_WARN_BYTES=1048576
   LLM_OLLAMA_INPUT_MAX_BYTES=0
   LLM_OLLAMA_ATTACHMENT_MAX_BYTES=16777216
   LLM_OLLAMA_ATTACHMENTS_MAX_BYTES=33554432
   LLM_OLLAMA_ATTACHMENT_MAX_COUNT=16
   LLM_OLLAMA_PDF_MAX_PAGES=24
   LLM_OLLAMA_PDF_DPI=120
   LLM_OLLAMA_ALLOW_LARGE_INPUT=0
   OLLAMA_NUM_PARALLEL=1
   OLLAMA_MAX_LOADED_MODELS=1
   OLLAMA_KEEP_ALIVE=5m
   OLLAMA_NO_CLOUD=1

FastFlow developer-input limits may also be overridden:

.. code-block:: text

   LLM_FASTFLOW_INPUT_WARN_BYTES=1048576
   LLM_FASTFLOW_INPUT_MAX_BYTES=0
   LLM_FASTFLOW_ATTACHMENT_MAX_BYTES=16777216
   LLM_FASTFLOW_ATTACHMENTS_MAX_BYTES=33554432
   LLM_FASTFLOW_ATTACHMENT_MAX_COUNT=16
   LLM_FASTFLOW_PDF_MAX_PAGES=24
   LLM_FASTFLOW_PDF_DPI=120
   LLM_FASTFLOW_ALLOW_LARGE_INPUT=0

Nginx
-----

Nginx owns the fixed loopback publication:

.. code-block:: text

   127.0.0.1:11434 -> nginx:11434 -> llm:11434

The provider containers themselves do not publish host ports. ``LDS_AI_TIMEOUT`` defaults
to ``1800`` seconds and is forwarded as ``LLM_PROXY_TIMEOUT_SECONDS``.

Compose Ownership
-----------------

Both provider definitions live in ``docker/compose/companion.yaml``. Runtime-generated
profile selectors enable exactly one provider. There are no tracked ``ai.yaml``,
``ai-nvidia.yaml``, ``ai-amd.yaml`` or ``ai-host-port.yaml`` variants.

Only Ollama NVIDIA/ROCm hardware augmentation is generated temporarily under
``docker/.runtime/``. The tracked Ollama image is
``infocyph/llm-ollama:latest``; the AMD override directly selects
``infocyph/llm-ollama:amd-latest``.
FastFlow's XDNA2 device/memlock contract is part of its tracked service definition.

Graphify
--------

``lds graphify [path]`` keeps Graphify as the owner of code AST extraction,
clustering, labeling, and unsupported semantic formats, while delegating supported
documentation/config structure to docker-tools.

The built-in host Graphify provider still uses:

.. code-block:: text

   http://llm.localhost:11434/v1

That host route is necessary because the Graphify CLI runs on the host. Tools-side AI
review runs inside Docker and resolves its provider directly from ``LDS_AI_RUNTIME``
(``llm-fastflow:11434`` for NPU; ``llm-ollama:11434`` otherwise).

There is no LocalDevStack Graphify HTTP proxy or Python compatibility adapter.

Document-first hybrid
~~~~~~~~~~~~~~~~~~~~~

When the active docker-tools image exposes the docstruct Graphify handoff,
``LDS_GRAPHIFY_DOCSTRUCT=auto`` enables the hybrid path automatically:

1. on a new graph, Graphify extracts code first with ``--code-only --no-cluster``;
2. Graphify performs its normal extract for code changes and semantic formats not owned
   by docstruct;
3. LocalDevStack excludes these docstruct-owned extensions from Graphify's raw semantic
   LLM pass:

   .. code-block:: text

      .md .markdown .rst .yaml .yml .json .toml .ini .cfg
      requirements*.txt constraints*.txt requirements/*.txt

4. docker-tools mechanically extracts those files with Pandoc plus the narrow
   RST/Sphinx/config parsers;
5. optional semantic review runs in bounded chunks against the active local model;
6. docker-tools emits a Graphify-compatible fragment;
7. Graphify's public ``merge-chunks`` validates that fragment;
8. docker-tools atomically replaces only the reserved ``docstruct_`` semantic layer;
9. ``graphify label`` reclusters and relabels the final combined graph.

This removes Markdown/RST/config parsing and recognized Python pip requirement manifests
from the fragile raw LLM extraction path while preserving Graphify's existing support for
other semantic formats such as papers/images. Arbitrary ``.txt`` prose is not claimed by
docstruct; only requirements/constraints naming patterns are treated as dependency
manifests.

The document merge never parses or replaces code nodes. It owns only its reserved
document namespace and also replaces legacy semantic nodes sourced from the supported
document/config extensions during migration.

Controls
~~~~~~~~

``LDS_GRAPHIFY_DOCSTRUCT``:

- ``auto`` (default): use docstruct when the Tools image supports it; otherwise warn
  and fall back to Graphify's existing semantic extraction;
- ``on``: require docstruct support;
- ``off``: use the legacy Graphify semantic path.

``LDS_GRAPHIFY_DOC_REVIEW``:

- ``auto`` (default): review bounded document chunks on the built-in local provider;
  if review fails, keep the deterministic structure and continue;
- ``on``: require semantic review to succeed;
- ``off``: use deterministic document structure only.

Explicit ``lds graphify --code-only`` remains a single Graphify structural build and
does not invoke docstruct.

Provider/runtime details
~~~~~~~~~~~~~~~~~~~~~~~~

FastFlow uses Graphify's generic OpenAI-compatible provider and defaults to thinking off:

.. code-block:: text

   backend=lds-fastflow
   extra_body={"think": false}

Ollama uses the custom local provider with explicit context headroom and reasoning
disabled:

.. code-block:: text

   backend=lds-ollama
   reasoning_effort=none

``GRAPHIFY_MAX_OUTPUT_TOKENS`` wins when set; otherwise
``LDS_GRAPHIFY_OUTPUT_TOKENS`` defaults to 8192.

Local semantic requests that remain on Graphify default to
``--token-budget 3000 --max-concurrency 1``. Explicit Graphify flags or
``LDS_GRAPHIFY_TOKEN_BUDGET`` / ``LDS_GRAPHIFY_MAX_CONCURRENCY`` can override
those defaults.

LocalDevStack requires ``graphifyy >= 0.9.65`` by default
(``LDS_GRAPHIFY_MIN_VERSION`` overrides the floor) and validates the selected model
through ``/v1/models`` before local-provider extraction.

Trust Boundary
--------------

Provider images have:

- no Docker socket;
- no project/repository bind mount by default;
- no automatic execution of model-generated shell commands, SQL or code;
- no silent cloud fallback in the common Tools AI client.

Repository-aware analysis should normally flow through Tools or an explicit provider
workspace override.

Platform Availability
---------------------

FastFlow is currently a ``linux/amd64`` XDNA2 runtime. LocalDevStack remains usable with
the ``ai`` profile disabled on unsupported platforms.

Troubleshooting
---------------

.. code-block:: bash

   lds llm runtime
   lds llm provider
   lds doctor
   lds logs llm
   curl -fsS http://127.0.0.1:11434/v1/models | jq

Use ``lds logs llm-fastflow`` or ``lds logs llm-ollama`` only when you explicitly
want the provider-specific service identity.

If FastFlow was expected but not selected, verify ``/dev/accel/accel0`` and the host
``amdxdna`` driver before forcing ``lds llm runtime npu``.
