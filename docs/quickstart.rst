Getting Started
===============

LocalDevStack is a Docker-based XAMPP alternative for PHP and Node.js local development.
The ``lds`` CLI manages Compose profiles, local domains, TLS, runtime builds, databases,
admin tools, background jobs, diagnostics, and optional local AI.

Prerequisites
-------------

Install Docker first.

Linux
   Docker Engine is preferred. Docker Desktop is also usable.

Windows
   Docker Desktop plus Git Bash. ``lds.bat`` bridges Windows invocation into the Bash CLI.

macOS
   Docker Desktop.

Docker is always a host-side requirement. Some developer utilities such as ``jq``,
``yq``, ``rg``, ``fd``, ``tree``, and ``shellcheck`` can be proxied through a running
``server-tools`` container when they are not installed on the host.

Recommended Layout
------------------

A common layout is::

   project-root/
   ├─ application/
   │  ├─ site1/
   │  ├─ site2/
   │  └─ ...
   └─ LocalDevStack/

The default project mount points at the sibling ``application/`` directory. Set
``PROJECT_DIR`` in ``docker/.env`` when the application directory lives elsewhere.

First-Time Setup
----------------

Clone the repository::

   git clone https://github.com/infocyph/LocalDevStack.git
   cd LocalDevStack

On Linux/macOS, prepare permissions and the ``lds`` symlink::

   chmod +x ./lds
   sudo ./lds setup permissions

Initialize workstation defaults::

   ./lds setup init

Choose optional service profiles::

   ./lds setup profile

The selector covers PostgreSQL, MySQL, MariaDB, MongoDB, Redis, Elasticsearch, and Local
AI. Re-running it replaces those catalog-managed choices while preserving generated
domain/runtime profiles.

Start the stack::

   ./lds up

The core stack includes ``server-tools``, Runner, Mailpit, Nginx, and Apache. Apache is
always available so a domain can choose it as its backend when needed.

Create the First Domain
-----------------------

The domain wizard requires the control plane to be running::

   ./lds setup domain

The wizard asks for application type, runtime version and routing details. PHP and Node
version selection remains explicit.

List generated domains and validate the graph::

   lds domain ls
   lds config validate

Trusted HTTPS
-------------

Once Tools has exported the LocalDevStack root CA, install it on the host.

Linux::

   sudo ./lds certificate install

Windows/Git Bash::

   lds.bat certificate install

Windows installs into ``CurrentUser\\Root``. Linux handles supported distro trust stores
and can also update the invoking user's NSS database when ``certutil`` is available.

macOS users may need to trust ``configuration/ssl/rootCA.pem`` manually in Keychain;
automatic Keychain import is not currently part of the host installer.

Useful First Checks
-------------------

::

   lds doctor
   lds urls
   lds images
   lds config show
   lds config validate
   lds status
   lds ps
   lds shell

``lds shell`` opens the grouped execution selector for domains, application
directories, services, containers, and Tools. Select by number or exact name; use a
qualified target when names collide.

``lds config show`` is redacted by default. Use ``--raw`` only when unredacted output is
deliberately required.

Document conversion is also available without starting the stack::

   lds convert README.md README.html

Pandoc runs from the Tools image; use ``lds convert --list-output-formats`` to inspect the
writers available in the current image.

Updating an Existing Installation
---------------------------------

On ``lds up`` or ``lds start``, known historical fixed LocalDevStack networks are safely
migrated to dynamic bridge networks when ownership can be proven. Named volumes are
preserved.

After an upgrade::

   lds doctor
   lds config validate

Refresh/recreate a selected service with::

   lds rebuild nginx

or all resolved services with::

   lds rebuild all

A normal ``lds restart`` does not intentionally pull newer moving image tags.

Safety Notes
------------

``lds support bundle`` is redacted by default; ``--full`` is intentionally raw.

``lds clean --yes`` is LocalDevStack-scoped. ``lds clean --global --yes`` performs
host-wide Docker pruning and can affect unrelated projects.

``lds down --volumes --yes`` removes persistent Compose data and should not be part of a
normal update.

Next Steps
----------

- Architecture: :doc:`concepts/architecture`
- Profiles/environment: :doc:`concepts/profiles-and-env`
- Storage: :doc:`concepts/storage-layout`
- Domains: :doc:`guides/domain-setup`
- Databases/clients: :doc:`guides/databases-and-clients`
- TLS: :doc:`guides/tls-and-certificates`
- Local AI: :doc:`guides/local-ai`
- Operations/support: :doc:`guides/operations-and-support`
- Ad-hoc runner: :doc:`guides/ad-hoc-runner`
- CLI reference: :doc:`reference/cli`
