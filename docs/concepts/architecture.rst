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
   llm-ollama

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

When the ``ai`` profile is enabled:

1. ``llm-ollama`` provides the Ollama runtime and persistent model store;
2. Tools consumes ``http://llm-ollama:11434`` internally;
3. Nginx exposes ``https://llm-ollama.localhost`` and the loopback-only native endpoint ``http://llm-ollama.localhost:11434`` to host clients;
4. ``lds ai`` delegates higher-level/operational AI to Tools;
5. ``lds llm`` delegates model/runtime operations to the bundled ``llm-ollama`` CLI.

The provider is one ``llm-ollama`` service declared in
``docker/compose/companion.yaml`` and enabled only by the ``ai`` profile. The service
keeps ``container_name: LLM_OLLAMA`` for current single-stack compatibility, while all
internal routing continues to use the Compose service/hostname ``llm-ollama``. Its image
is ``infocyph/llm-ollama:${LDS_LLM_ARCH}``: CPU/NVIDIA resolve to ``latest`` and
AMD/ROCm resolves to ``amd-latest``. ``LDS_LLM_ARCH`` is derived from the effective
runtime rather than maintained as an independent version selector.

No AI-specific Compose files are tracked. ``lds`` generates a temporary fragment under
``docker/.runtime/`` only when NVIDIA GPU access, AMD device mappings, or loopback
host-port exposure is required, then removes it after the Compose command. The service
also forwards the configured ``LDS_AI_MODEL`` to the provider as ``LLM_OLLAMA_MODEL`` and
passes the documented provider safety/tuning settings from ``docker/.env``. For AMD
runtime on an AMD CPU, LocalDevStack persists ``LDS_AI_IGPU_ENABLE=1`` and forwards it
as ``OLLAMA_IGPU_ENABLE=1`` so Ollama admits the integrated Radeon GPU.

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
- databases;
- database admin clients;
- Nginx or Apache;
- ordinary generated runtimes.

The separate ad-hoc ``lds run --sock`` option is an explicit opt-in and should be used
only with trusted Dockerfiles/code.

``llm-ollama`` also receives no project/repository mount by default. AI output is not
automatically executed as shell, SQL, or code.

Persistence
-----------

Runtime-generated vhosts, certificate material, databases, Mailpit data, PHP-FPM state,
Tools control state, and AI models use named Docker volumes.

Host-editable/generated configuration, logs, SOPS/Age state, optional SSH material, and
public TLS exports remain under the repository.

See :doc:`storage-layout` for ownership details.
