Architecture
============

LocalDevStack separates host orchestration, trusted control-plane duties, web routing,
application runtimes, persistent service state, and optional local AI.

Host Orchestration
------------------

``lds`` / ``lds.bat``
   Host-side orchestration for setup, profiles, Compose, diagnostics, rebuilds, domains,
   TLS installation, support tooling, and convenience wrappers.

``docker/release.env``
   Tracked release/build defaults that genuinely vary, such as ``SCRIPTOMATIC_REF``. Fixed infrastructure image names live directly in Compose.

``docker/.env``
   User-owned LocalDevStack configuration.

``configuration/compose/``
   Generated runtime Compose fragments discovered and merged into the effective stack.

Execution Navigation
--------------------

``lds shell`` is the canonical host-side execution and navigation surface. It resolves
discovered domains, direct application directories under ``server-tools:/app``, exact
current-project Compose services, exact Docker containers, and the trusted Tools target
into one normalized execution context.

Unqualified targets resolve deterministically in this order: discovered domain,
``tools``, exact Compose service, exact Docker container, then an exact direct child
under ``/app``. Qualified ``domain:``, ``app:``, ``service:``, ``container:``, and
``utility:tools`` selectors bypass collisions.

The compatibility commands ``core``, ``cli``, ``stack exec``, and the
execution-oriented ``tools`` subcommands delegate to the same shell-context execution
layer while retaining their intentionally narrower public contracts.

Core Services
-------------

``server-tools``
   Trusted control plane. Tools owns vhost generation, certificate generation, durable
   domain/runtime metadata, admin UI behavior, secrets helpers, Git/dev utilities,
   monitoring, and AI-consumer commands.

``runner``
   Background execution layer for Supervisor, cron definitions, and log rotation.

``mailpit``
   Persistent local mail capture with LocalDevStack TLS material.

``nginx``
   Host-facing HTTP/HTTPS front door. Ports 80/443 are published here.

``apache``
   Always-available alternate HTTP backend. Individual domains decide whether to route
   through Apache; the container remains part of the core stack so CLI and Admin Panel
   domain creation retain the same capabilities.

Application Runtimes
--------------------

PHP and Node runtimes are generated per selected version. The domain wizard preserves
the user's explicit version choice.

Generated image identities are::

   localdevstack-php:<selected-version>
   localdevstack-node:<selected-version>

Both runtime families use Alpine variants. Scriptomatic supplies common runtime bootstrap
behavior and installs Toolset according to its own current contract.

Optional Data Services
----------------------

Catalog-managed profiles currently include::

   postgresql
   mysql
   mariadb
   mongodb
   redis
   elasticsearch
   ai

Related admin clients are enabled through the same profiles where applicable:
CloudBeaver, RedisInsight, Mongo Express, and Kibana.

An advanced ``filebeat`` profile exists in Compose for Elastic log ingestion. It is not
part of the normal guided catalog and should be enabled deliberately alongside
Elasticsearch.

Networking
----------

LocalDevStack keeps three logical networks::

   Frontend
   Backend
   DataStore

Docker assigns their address ranges dynamically. Core services do not rely on fixed
private subnet addresses.

Service-to-service traffic uses Docker DNS names such as::

   server-tools
   runner
   mailpit
   nginx
   apache
   postgres
   mysql
   mariadb
   mongodb
   redis
   elasticsearch
   llm
   llm-ollama
   llm-fastflow

The historical ``lds vpn-fix`` command remains only as a deprecated compatibility
message because LocalDevStack no longer owns fixed bridge subnets.

Legacy Network Migration
------------------------

``lds up`` and ``lds start`` call the legacy-network migration guard before starting the
stack.

The migration is deliberately conservative:

1. only the known historical network names are considered;
2. the expected historical subnet must match;
3. ownership labels must prove the network belongs to LocalDevStack;
4. attached containers must also belong to the effective Compose project;
5. Compose is brought down without ``-v``;
6. only proven legacy networks are removed.

Persistent named volumes are not removed by this migration.

Domain Flow
-----------

A normal domain flow is:

1. ``lds setup domain`` delegates domain/runtime generation to Tools;
2. Tools writes Nginx/Apache vhosts into persistent named volumes;
3. Tools writes runtime Compose fragments under ``configuration/compose/``;
4. generated runtime/server profiles are updated;
5. LocalDevStack recreates the effective stack;
6. Nginx routes through Docker service names or PHP-FPM sockets.

Removing a domain follows the corresponding Tools ``rmhost`` state and removes generated
profiles before recreating the stack.

AI Flow
-------

When the ``ai`` profile is enabled, LocalDevStack selects exactly one provider:

.. code-block:: text

   supported XDNA2 NPU -> llm-fastflow
   NVIDIA/ROCm/CPU     -> llm-ollama

The selected service owns the common Docker DNS alias ``llm`` on internal port ``11434``.
Tools consumes ``http://llm:11434`` and Nginx exposes ``https://llm.localhost`` plus the
loopback-only native route ``http://127.0.0.1:11434``. Provider-specific Nginx routes
remain available for diagnostics/native operations.

``lds ai`` delegates higher-level operational/developer AI to Tools. ``lds llm`` resolves
the active provider and dispatches provider/model operations to ``llm-fastflow`` or
``llm-ollama`` as appropriate.

Both provider definitions live in ``docker/compose/companion.yaml`` but dynamic profile
selection ensures they are mutually exclusive. FastFlow uses ``infocyph/llm-fastflow:latest``
for ``npu``. Ollama uses ``latest`` for CPU/NVIDIA and ``amd-latest`` for AMD/ROCm.

FastFlow and Ollama both default to ``qwen3.5:9b`` unless ``LDS_AI_MODEL`` is
explicitly set.

NVIDIA/ROCm hardware augmentation is generated temporarily under ``docker/.runtime/``.
FastFlow's XDNA2 device and memlock contract is tracked directly in its service definition.
Project Identity
----------------

The Compose project contract defaults to ``LocalDevStack``. Label-scoped commands such
as diagnostics, events, support bundles, and cleanup use the effective Compose project
name instead of deriving identity from the checkout directory.

An explicit ``COMPOSE_PROJECT_NAME`` override therefore remains coherent with these
operations.

Tool Proxying
-------------

Some non-privileged developer utilities can be resolved from ``server-tools`` when they
are unavailable on the host. Host binaries win first. Docker and other host-control
commands are never proxied.

Disable proxying for a command with::

   LDS_PROXY_TOOLS=0 lds <command>

Trust Boundaries
----------------

``server-tools`` and ``runner`` intentionally receive ``/var/run/docker.sock`` because
their supported workflows control sibling containers. Docker socket access is
equivalent to powerful host Docker control.

The Docker socket is not mounted into:

- ``llm-ollama``;
- ``llm-fastflow``;
- databases;
- database admin clients;
- Nginx or Apache;
- ordinary generated runtimes.

The separate ad-hoc ``lds run --sock`` option is an explicit opt-in and should be used
only with trusted Dockerfiles/code.

Neither LLM provider receives a project/repository mount by default. AI output is not
automatically executed as shell, SQL, or code.

Persistence
-----------

Runtime-generated vhosts, certificate material, databases, Mailpit data, PHP-FPM state,
Tools control state, and AI models use named Docker volumes.

Host-editable/generated configuration, logs, SOPS/Age state, optional SSH material, and
public TLS exports remain under the repository.

See :doc:`storage-layout` for ownership details.
