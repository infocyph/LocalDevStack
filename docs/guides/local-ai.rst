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

``server-tools`` uses only the common provider-neutral contract:

.. code-block:: text

   LDS_AI_PROVIDER=llm
   LDS_AI_URL=http://llm:11434
   LDS_AI_MODEL=<effective provider model>

Therefore ``lds ai`` commands do not need to know which provider owns ``llm``:

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

``lds graphify [path]`` uses the common LocalDevStack endpoint and selects the
Graphify backend from the active provider.

For the built-in LocalDevStack endpoint, Graphify runs through an ephemeral
provider definition created only for that invocation. The provider definition itself
is never written into the target repository or ``~/.graphify/providers.json``.

Local Graphify runs always use a localhost structured-output compatibility proxy.
The temporary provider points to ``127.0.0.1:<ephemeral>/v1``, and the proxy
forwards requests to ``http://llm.localhost:11434/v1``. Community-label requests
pass through unchanged; semantic-extraction requests use the active provider's native
structured-output mechanism.

FastFlow / NPU:

.. code-block:: text

   backend=lds-fastflow
   model=<effective FastFlow model>
   extra_body={"think": false}

Ollama / CPU, NVIDIA or ROCm:

.. code-block:: text

   backend=lds-ollama
   model=<effective Ollama model>
   reasoning_effort=none

The Ollama provider definition also keeps explicit context headroom for Graphify's
local chunks. Both local providers default to ``--token-budget 4000
--max-concurrency 1`` unless the caller supplied those flags. These limits and the
no-thinking request are separate protections: the former prevents local context/resource
pressure, while the latter keeps reasoning out of the structured response channel.

Structured extraction is provider-specific:

* FastFlow / Qwen3.5 uses native tool calling with a single ``submit_graph``
  function whose arguments follow Graphify's node/edge/hyperedge schema. The proxy
  requests FastFlow in streaming mode and stops reading as soon as FastFlow emits
  the completed ``tool_calls`` delta, then converts that call into the normal
  non-stream assistant JSON content Graphify expects. This avoids waiting for model
  EOS on FastFlow's non-stream path. FastFlow currently ignores OpenAI
  ``response_format`` on its chat-completions path, so tool calling is the
  supported structured channel.
* Ollama uses its OpenAI-compatible ``response_format.type=json_schema`` path with
  the same Graphify schema and ``temperature=0``. Ollama maps that schema to its
  native structured-output ``format`` field.

A structurally valid all-empty graph remains valid and is passed back to Graphify
unchanged; Graphify then decides whether to retry it as a hollow extraction.

Structured generations are deliberately bounded independently of Graphify's larger
general output allowance. LocalDevStack defaults a structured extraction to 8192 output
tokens (``LDS_GRAPHIFY_OUTPUT_TOKENS``) and a 300-second provider timeout
(``LDS_GRAPHIFY_STRUCTURED_TIMEOUT``). The output budget is also included when
LocalDevStack derives Ollama context headroom, so the request budget and context window
remain consistent instead of relying on fixed padding.

LocalDevStack deliberately performs exactly one provider-native structured request
per Graphify extraction attempt. It does not add its own structured retry or
free-form fallback chain. Genuine provider output truncation remains
``finish_reason=length`` and may be bisected by Graphify's adaptive retry. A transport
timeout is returned as a timeout error instead: it is not rewritten as truncation,
because splitting a slow request does not prove the response was too large. Increase
``LDS_GRAPHIFY_STRUCTURED_TIMEOUT`` or reduce ``--token-budget`` when needed.

For local providers, hidden retry amplification is bounded at both outer layers:
the OpenAI SDK retry count defaults to zero (``LDS_GRAPHIFY_SDK_RETRIES=0``) and
Graphify's adaptive retry depth defaults to one
(``LDS_GRAPHIFY_MAX_RETRY_DEPTH=1``). Explicit
``GRAPHIFY_MAX_RETRIES`` / ``GRAPHIFY_MAX_RETRY_DEPTH`` values still win.

Detailed suspect-response logging is optional and does not control the compatibility
proxy. Enable it with:

.. code-block:: bash

   LDS_GRAPHIFY_DIAGNOSTICS=1 lds graphify .

When enabled, a bounded assistant-content preview is printed and the full suspect
assistant response is stored as JSON Lines in:

.. code-block:: text

   <target>/graphify-out/lds-graphify-diagnostics.jsonl

The diagnostic record contains request controls such as model, ``think``,
``reasoning_effort``, finish reason, and token usage, but never stores the Graphify
prompt or source corpus. ``LDS_GRAPHIFY_DIAGNOSTIC_PREVIEW`` controls the terminal
preview size (minimum 256, default 4096). ``LDS_GRAPHIFY_DIAGNOSTIC_LOG`` overrides
the JSONL path.

FastFlow Graphify still defaults to ``LDS_GRAPHIFY_THINK=off``. The current
FastFlow Qwen3.5 non-stream parser can leave ``<think>...</think>`` text inside
``message.content``, so thinking is intentionally kept off for Graphify's
structured extraction path. ``LDS_GRAPHIFY_THINK=on`` and
``LDS_GRAPHIFY_THINK=auto`` remain diagnostic overrides, not recommended defaults.

Before extraction, LocalDevStack verifies the installed Graphify CLI is compatible
(``graphifyy >= 0.9.65`` by default, overrideable with ``LDS_GRAPHIFY_MIN_VERSION``)
and checks ``/v1/models``, failing fast when the selected model is absent.

When both ``<target>/graphify-out/graph.json`` and
``<target>/graphify-out/manifest.json`` exist, ``lds graphify`` keeps using
Graphify's lower-level ``extract`` pipeline, which automatically switches to
incremental mode: only changed code/docs/papers/images are re-extracted, deleted or
excluded sources are reconciled, and the result is merged into the existing graph.
This is intentionally preferred over the literal ``graphify update`` CLI command,
because current Graphify ``update`` refreshes code only and delegates semantic
document refreshes to the assistant update workflow. Pass ``--force`` only when a
full rebuild is intentionally required.

Override the local chunk defaults with explicit Graphify flags, or set
``LDS_GRAPHIFY_TOKEN_BUDGET`` / ``LDS_GRAPHIFY_MAX_CONCURRENCY``. If a local
model reports ``Max length reached!``, reduce the token budget further, for example:

.. code-block:: bash

   lds graphify . --token-budget 3000 --max-concurrency 1

Explicit ``OPENAI_BASE_URL`` (FastFlow path) or ``OLLAMA_BASE_URL`` (Ollama path)
remains caller-controlled and bypasses the local-provider preflight. Extraction still
uses ``--no-cluster`` followed by ``cluster-only`` so clustering occurs once.

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
