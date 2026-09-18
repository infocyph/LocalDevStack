Local AI
========

LocalDevStack can run a local Ollama-compatible provider as an optional profile. The
provider/runtime is llm-sm; Tools remains an AI consumer and never embeds a second
Ollama runtime.

Enable AI
---------

Use the guided service setup::

   lds setup profile

Select Local AI / the ai profile.

The default provider contract is::

   LDS_AI_ENABLED=auto
   LDS_AI_PROVIDER=ollama
   LDS_AI_URL=http://llm-sm:11434
   LDS_AI_MODEL=qwen2.5:3b

The explicit LocalDevStack model default avoids ambiguity when several models are
installed in the persistent Ollama store.

Runtime Modes
-------------

Select the provider runtime explicitly::

   lds llm runtime cpu
   lds llm runtime nvidia
   lds llm runtime amd

CPU and NVIDIA use the standard infocyph/llm-sm:latest image. AMD/ROCm uses
infocyph/llm-sm:amd-latest.

LocalDevStack does not attempt unreliable automatic GPU detection.

Access
------

Container-to-container provider endpoint::

   http://llm-sm:11434

User-facing HTTPS endpoint::

   https://llm.localhost

Nginx owns the host-facing route and preserves streaming behavior for Ollama/OpenAI-style
API calls.

Direct host Ollama access is disabled by default. To opt in::

   lds llm host-port on

The direct binding is loopback-only::

   127.0.0.1:11434

Disable it again with::

   lds llm host-port off

AI vs LLM Commands
------------------

lds ai is for Tools-owned operational intelligence::

   lds ai status
   lds ai ask "explain this error"
   lds ai explain ...
   lds ai troubleshoot ...
   lds ai review ...
   lds ai repo-review ...
   lds ai graphify ...

lds llm is for provider/model runtime management::

   lds llm models
   lds llm ps
   lds llm show <model>
   lds llm pull <model>
   lds llm rm <model>
   lds llm run <model>
   lds llm chat ...
   lds llm version

This separation keeps application/operational AI in Tools and model lifecycle inside
the provider image.

Model Persistence
-----------------

Ollama state persists in the LLMModels named volume mounted at /root/.ollama.
Removing/recreating the container does not remove installed models unless the volume is
explicitly deleted.

Do not use destructive docker compose down -v during normal LocalDevStack upgrades.

Selecting a Different Model
---------------------------

Install the model through the provider::

   lds llm pull <model>

Then set LDS_AI_MODEL in docker/.env to make Tools use that model by default.
Shell environment overrides still have the highest precedence.

Privacy and Trust Boundaries
----------------------------

By default, llm-sm receives:

- no Docker socket;
- no project/repository bind mount;
- no host port;
- only its model volume and the LocalDevStack networks needed for provider access.

Tools may send bounded/sanitized context to the local provider when the user invokes an
AI feature. Deterministic monitoring and system checks remain the source of truth.

LocalDevStack does not:

- fall back silently to a cloud AI provider;
- automatically execute model-generated shell commands;
- automatically execute model-generated SQL;
- automatically execute generated code.

Graphify
--------

lds ai graphify delegates Graphify-assisted analysis to the Tools AI layer. The
LocalDevStack AI provider remains only the model runtime; Graphify integration does not
grant llm-sm direct repository access.

Diagnostics
-----------

Show provider state through Tools::

   lds ai status

Check the LocalDevStack stack non-destructively::

   lds doctor

List convenience endpoints::

   lds urls
