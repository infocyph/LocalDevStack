Architecture
============

LocalDevStack is split into small, purpose-specific layers.

Core Components
---------------

lds / lds.bat
   Host-side orchestrator for setup, profiles, Compose, diagnostics, runtime rebuilds,
   domains, TLS, and convenience commands.

Nginx
   Front door for local HTTP/HTTPS traffic. It routes PHP-FPM, optional Apache,
   Node applications, admin UIs, Mailpit, and llm.localhost.

Apache
   Optional HTTP backend for projects that explicitly choose the Apache path.

PHP / Node runtimes
   Locally built, version-specific runtime images. The domain wizard preserves the
   selected PHP/Node version and uses Alpine variants.

Tools
   Trusted control plane for vhost generation, certificates, admin UI, secrets,
   Git helpers, monitoring, and AI-consumer commands.

Runner
   Background execution layer for Supervisor, cron, and log rotation.

llm-sm
   Optional local AI provider. It is enabled only through the ai profile and is
   separate from Tools.

Networking
----------

LocalDevStack keeps three logical networks::

   Frontend
   Backend
   DataStore

Docker assigns their address ranges dynamically. Core services do not depend on
hard-coded 172.28/29/30 addresses.

Service-to-service communication uses Docker DNS names such as::

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
   llm-sm

The legacy lds vpn-fix workflow is deprecated because LocalDevStack no longer owns
fixed private subnets.

Runtime Flow
------------

A normal web-domain flow is:

1. lds setup domain delegates domain/runtime generation to Tools.
2. Tools writes HTTP vhosts into persistent named volumes.
3. Tools writes runtime Compose fragments under configuration/compose/.
4. Nginx routes by Docker service name or PHP-FPM socket.
5. Selected PHP/Node runtime images are built only for the chosen versions.

For optional AI:

1. the ai profile starts llm-sm;
2. Tools consumes http://llm-sm:11434 internally;
3. Nginx exposes https://llm.localhost;
4. lds ai delegates operational AI to Tools;
5. lds llm delegates provider/model management to llm-sm.

Trust Boundaries
----------------

server-tools and runner intentionally receive /var/run/docker.sock because their
supported workflows control sibling containers. Docker socket access is equivalent
to powerful host Docker control.

The Docker socket is not mounted into:

- llm-sm;
- databases;
- database admin clients;
- Nginx/Apache;
- ordinary runtime services.

llm-sm also receives no project/repository mount by default. AI output is not
automatically executed as shell, SQL, or code.

Persistence
-----------

Runtime-generated vhosts, certificate material, databases, Mailpit state, runtime
sockets/pools, and AI models use named volumes. Host-editable/generated configuration,
logs, SOPS state, optional SSH material, and public TLS exports remain under the repository.
