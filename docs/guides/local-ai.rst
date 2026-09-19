Local AI
========

LocalDevStack can run a local Ollama-compatible provider as an optional profile.
``llm-sm`` owns the provider/runtime; Tools remains the higher-level AI consumer and
never embeds a second Ollama runtime.

Enable AI
---------

Use the guided profile setup::

   lds setup profile

Select Local AI / the ``ai`` profile.

The default consumer contract is::

   LDS_AI_ENABLED=auto
   LDS_AI_PROVIDER=ollama
   LDS_AI_URL=http://llm-sm:11434
   LDS_AI_MODEL=qwen2.5:3b

The explicit model default avoids ambiguity when multiple models are installed in the
persistent Ollama store.

Runtime Modes
-------------

LocalDevStack detects the preferred runtime during environment setup. Detection is intentionally capability-based rather than CPU-vendor based:

- NVIDIA when ``nvidia-smi`` is usable;
- AMD only when both ``/dev/kfd`` and ``/dev/dri`` are present for ROCm;
- CPU otherwise.

An AMD CPU alone does **not** select the AMD image.

The single provider service uses::

   image: infocyph/llm-sm:${LDS_LLM_ARCH}

The persisted mapping is:

- ``cpu`` -> ``LDS_LLM_ARCH=latest``;
- ``nvidia`` -> ``LDS_LLM_ARCH=latest`` plus the NVIDIA GPU overlay;
- ``amd`` -> ``LDS_LLM_ARCH=amd-latest`` plus the AMD device overlay.

Override detection explicitly when required::

   lds llm runtime cpu
   lds llm runtime nvidia
   lds llm runtime amd

Changing runtime mode updates both ``LDS_AI_RUNTIME`` and ``LDS_LLM_ARCH`` in ``docker/.env``. Recreate/start the service afterward so the Compose override changes take effect.

Access
------

Internal provider endpoint::

   http://llm-sm:11434

User-facing HTTPS endpoint::

   https://llm.localhost

Internal Docker consumers should use the service endpoint directly rather than routing
through Nginx.

Direct host Ollama access is disabled by default. Opt in with::

   lds llm host-port on

The default direct binding is loopback-only::

   127.0.0.1:11434

Show/disable it with::

   lds llm host-port status
   lds llm host-port off

The port can be changed through ``LLM_SM_PORT`` when direct host access is enabled.

AI vs LLM Commands
------------------

``lds ai`` is for Tools-owned operational/developer intelligence::

   lds ai status
   lds ai ask "explain this error"
   lds ai explain ...
   lds ai troubleshoot ...
   lds ai review ...
   lds ai repo-review ...
   lds ai graphify ...

``lds llm`` is for the provider/model CLI::

   lds llm models
   lds llm ps
   lds llm show <model>
   lds llm pull <model>
   lds llm rm <model>
   lds llm unload <model>
   lds llm run <model>
   lds llm ask "Explain dependency injection briefly"
   lds llm chat ...
   lds llm prompt ...
   lds llm code ...
   lds llm review ...
   lds llm json ...
   lds llm ai-commit ...
   lds llm ollama ...
   lds llm api ...
   lds llm version

This separation keeps application/operational AI in Tools and model/runtime behavior in
the provider image.

Always invoke provider commands through ``lds llm`` inside LocalDevStack. The repository
does not expose a root ``compose.yml`` because ``lds`` assembles the effective Compose
project from the tracked main file, env layers, optional extras, and runtime-specific
temporary overrides. A bare ``docker compose exec llm-sm ...`` from the LocalDevStack
repository root therefore fails at the host Compose layer before ``llm-sm`` runs.

Model Persistence
-----------------

Ollama state persists in the ``LLMModels`` named volume mounted at
``/root/.ollama``.

Container recreation/image replacement does not delete user-pulled models while the
volume is retained.

Do not use ``lds down --volumes --yes`` or destructive volume cleanup during a normal
upgrade.

Selecting a Different Model
---------------------------

Pull a model explicitly::

   lds llm pull <model>

Then set ``LDS_AI_MODEL`` in ``docker/.env`` if Tools should use that model by default.
A command-scoped shell value remains the highest-precedence override.

The provider CLI does not silently download a missing model for an unrelated command.

Privacy and Trust Boundaries
----------------------------

The base ``llm-sm`` service lives in ``docker/compose/companion.yaml`` and is gated by the ``ai`` profile. There are no tracked ``ai-*.yaml`` files. When NVIDIA, AMD/ROCm, or direct loopback access is selected, ``lds`` writes a small temporary Compose fragment under ``docker/.runtime/``, uses it for that Compose invocation, and removes it immediately afterward.

By default, ``llm-sm`` receives:

- no Docker socket;
- no project/repository bind mount;
- no host port;
- only the model volume and LocalDevStack networks needed for provider access.

Tools may send bounded/sanitized context to the local provider when the user invokes an
AI feature. Deterministic monitoring/system checks remain the source of truth.

LocalDevStack does not:

- silently fall back to a cloud AI provider;
- automatically execute model-generated shell commands;
- automatically execute model-generated SQL;
- automatically execute generated code.

Repository Context
------------------

LocalDevStack intentionally does not mount the project/repository into llm-sm by default.

Repository-aware analysis should normally use the Tools consumer layer::

   lds ai review ...
   lds ai repo-review ...
   lds ai graphify ...

For direct provider commands, file/PDF/image paths must exist inside the provider
container. The upstream ``llm-sm`` CLI also supports stdin-based flows such as
``ai-commit --diff-stdin`` when explicitly invoked.

Graphify
--------

``lds ai graphify`` delegates Graphify-assisted analysis to the Tools AI layer.
``llm-sm`` remains only the model provider and does not gain direct repository access
from this integration.

Diagnostics
-----------

::

   lds ai status
   lds llm models
   lds doctor
   lds urls
   lds logs llm-sm

Platform Availability
---------------------

The current published ``llm-sm`` standard and AMD images have a linux/amd64 only
platform contract.

LocalDevStack itself can still be used on arm64 with the ``ai`` profile disabled. Native
arm64 local-AI support should only be advertised after the provider publishes and
validates that platform.
