Profiles and Environment
========================

LocalDevStack uses Docker Compose profiles to keep optional services explicit while the
core development/control plane remains available.

Guided Profile Setup
--------------------

Use::

   lds setup profile

The host-side service catalog is tracked at::

   docker/catalog/services.psv

It describes service/profile names, setup defaults/prompts, convenience URLs,
persistent-volume metadata, and supported AI runtime modes.

Catalog-managed optional profiles are:

- ``postgresql``;
- ``mysql``;
- ``mariadb``;
- ``mongodb``;
- ``redis``;
- ``elasticsearch``;
- ``ai``.

PHP/Node domain runtimes are selected separately by the domain wizard.

Replacement Semantics
---------------------

Re-running ``lds setup profile`` replaces only the catalog-managed service selection.
Generated domain/runtime profiles are preserved.

For example, if the existing profile set is conceptually::

   mysql,redis,ai,apache,php84

and the guided selector is re-run with only PostgreSQL selected, the resulting set keeps
the generated runtime/server profiles::

   postgresql,apache,php84

while removing the previously selected catalog services.

Choosing ``NONE`` clears all catalog-managed service profiles while preserving generated
domain/runtime profiles. Choosing ``CANCEL / Back`` leaves the existing selection
unchanged. When a selected service is configured again, existing user values are reused
as prompt defaults; secret-like values are preserved without printing them.

Manual profile operations remain available::

   lds profiles list
   lds profiles add redis
   lds profiles remove redis

The advanced Compose-only ``filebeat`` profile can be enabled manually when required.
It should be used with Elasticsearch.

Environment Ownership
---------------------

Tracked product/release defaults live in::

   docker/release.env

User LocalDevStack settings live in::

   docker/.env

The repository-root ``.env`` remains project/application-facing state where applicable;
it is not the release-default manifest.

Effective LocalDevStack control precedence is::

   built-in fallback
       < docker/release.env
       < docker/.env
       < command-scoped shell environment

LocalDevStack reads dotenv values as data. It does not blindly shell-source
``docker/.env``.

Initialization
--------------

Run::

   lds setup init

to initialize workstation defaults such as:

- ``TZ``;
- ``GIT_USER_NAME``;
- ``GIT_USER_EMAIL``.

Setup also maintains LocalDevStack host identity values such as ``WORKING_DIR`` and,
on non-root Unix invocation, ``USER``, ``UID``, and ``GID``.

Common Configuration Keys
-------------------------

Frequently used user overrides include::

   PROJECT_DIR=/path/to/application
   HTTP_PORT=80
   HTTPS_PORT=443
   COMPOSE_PROFILES=...
   COMPOSE_PROJECT_NAME=LocalDevStack

Fixed Infrastructure Images
---------------------------

Tools, Runner, Nginx, and Apache are fixed LocalDevStack product components and are
declared directly in Compose as their published ``:latest`` images. LocalDevStack does
not expose redundant ``LDS_*_IMAGE`` overrides for them.

``docker/release.env`` is reserved for defaults that genuinely vary, such as
``SCRIPTOMATIC_REF``.

Useful Inspection Commands
--------------------------

Show environment keys without printing values::

   lds config env-used

Show effective Compose config with secrets redacted::

   lds config show

JSON form::

   lds config show --json

Show raw effective Compose config only when intentionally needed::

   lds config show --raw

Show resolved services/profiles::

   lds config services
   lds config profiles

Validate Compose and mounted scheduler configuration::

   lds config validate

Show selected/catalog profiles::

   lds profiles list

Image Defaults
--------------

The default policy is:

   Prefer the moving Alpine variant when the image family provides a suitable one;
   otherwise use its normal moving latest tag.

Examples:

- PostgreSQL defaults to ``postgres:alpine``.
- Tools, Runner, Nginx, and Apache use their published ``:latest`` aliases.
- Standard local AI uses ``infocyph/llm-ollama:latest``.
- AMD local AI uses ``infocyph/llm-ollama:amd-latest``.
- Elasticsearch, Kibana, and Filebeat share ``ELASTICSEARCH_VERSION`` and default to ``latest``.

Run::

   lds images

to inspect the effective image set. Fixed product images are reported directly; database/runtime/LLM selections reflect their actual configurable state.

Runtime Version Selection
-------------------------

Tools publishes the runtime catalog used by ``mkhost``. The user still selects a runtime
version per domain.

PHP selection becomes:

- ``PHP_VERSION`` build input;
- ``localdevstack-php:<selected-version>`` image identity;
- Alpine PHP-FPM base.

Node selection becomes:

- ``NODE_VERSION`` build input;
- ``localdevstack-node:<selected-version>`` image identity;
- Alpine Node base.

Runtime rebuilds keep normal Docker build cache while using ``--pull`` to refresh the
selected base.

Scriptomatic
------------

Runtime builds consume Scriptomatic from ``main`` by default::

   SCRIPTOMATIC_REF=main

A full 40-character commit SHA is also accepted for reproducible debugging/release
builds. Other arbitrary refs are rejected.

AI Settings
-----------

Important AI settings include::

   LDS_AI_ENABLED=auto
   LDS_AI_PROVIDER=ollama
   LDS_AI_URL=http://llm-ollama:11434
   LDS_AI_MODEL=qwen3:14b
   LDS_AI_RUNTIME=<optional explicit cpu|nvidia|amd>
   LDS_AI_IGPU_ENABLE=<auto-derived 0|1>

When ``LDS_AI_RUNTIME`` is not explicitly set, LocalDevStack detects the preferred
runtime for the Compose invocation. NVIDIA is selected only when ``nvidia-smi`` is
usable; AMD is selected only when the ROCm Linux device nodes ``/dev/kfd`` and
``/dev/dri`` are present; otherwise CPU is selected.

``LDS_LLM_ARCH`` is derived from that runtime (``latest`` for CPU/NVIDIA,
``amd-latest`` for AMD). It is not a separate user-facing image version selector.
Using ``lds llm runtime ...`` persists the explicit runtime choice, matching derived
tag and the automatic ``LDS_AI_IGPU_ENABLE`` value. On an AMD CPU with the AMD runtime,
the automatic value is ``1`` and is forwarded as ``OLLAMA_IGPU_ENABLE=1``; otherwise
it is ``0``.

Use::

   lds llm runtime <cpu|nvidia|amd>

to override the detected runtime behavior.

The selected ``LDS_AI_MODEL`` is also forwarded to the provider as
``LLM_OLLAMA_MODEL``, so Tools and ``lds llm`` share the same default model.

Provider-side options accepted in ``docker/.env`` include::

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

Tools consumer settings remain separate::

   LDS_AI_CONNECT_TIMEOUT=2
   LDS_AI_PREFLIGHT_TIMEOUT=5
   LDS_AI_TIMEOUT=1800
   LDS_AI_AVAILABILITY_TTL=5
   LDS_AI_MAX_CONTEXT_BYTES=524288
   LDS_AI_MAX_REQUEST_BYTES=1048576
   LDS_AI_MAX_RESPONSE_BYTES=2097152

Only generation/analysis receives the long 1800-second default. Connect and preflight
checks stay fast. The same generation timeout is passed to Nginx as
``LLM_PROXY_TIMEOUT_SECONDS`` for the dedicated LLM proxy path.

The LLM service itself is tracked only in ``docker/compose/companion.yaml``. There are
no tracked AI runtime-variant YAML files; ``lds`` creates temporary fragments under
``docker/.runtime/`` only for NVIDIA or AMD/ROCm augmentation.

Compose Extras
--------------

LocalDevStack discovers ``*.yaml`` and ``*.yml`` files under::

   configuration/compose/

and merges them after the built-in product Compose files. This is where generated runtime
fragments live.

Use the global option::

   lds --reload-extras <command>

when a workflow must force an extras rescan before the command.

Tool Proxy Control
------------------

Proxy-safe utilities can fall back to ``server-tools`` when unavailable on the host.
Disable that behavior with::

   LDS_PROXY_TOOLS=0 lds <command>

Host-control utilities such as Docker, mount operations, chmod/chown, and system service
control are never proxied.
