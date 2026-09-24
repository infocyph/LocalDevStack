Operations and Support
======================

This guide covers routine stack operations, upgrades, diagnostics, support bundles, and
cleanup boundaries.

Stack Lifecycle
---------------

Start in the foreground/default Compose mode::

   lds up

Start detached::

   lds start

Stop/remove Compose containers while preserving named volumes::

   lds down

Restart the entire stack::

   lds restart

Restart only selected services::

   lds restart nginx
   lds restart nginx server-tools

A service-specific restart uses Compose ``restart`` and does not perform the full
stop/start path.

Status and Logs
---------------

::

   lds status
   lds ps
   lds logs
   lds logs nginx
   lds logs nginx --follow
   lds logs nginx --since 10m
   lds logs nginx --grep project.localhost

``lds status`` delegates the richer status view to Tools. ``lds ps`` uses Compose
directly.

Execute a command in an exact current-project service through the canonical
execution surface::

   lds shell service:nginx -- nginx -t

Open an interactive shell in that service::

   lds shell service:nginx

``lds stack exec nginx ...`` and the top-level ``lds exec nginx ...`` alias remain
service-only compatibility forms.

Stack Diff
----------

Compare desired Compose images with running container images::

   lds stack diff

Show the effective config alongside the diff::

   lds stack diff --config

Machine-readable diff output requires ``jq``::

   lds stack diff --json

Rebuild and Refresh
-------------------

A normal restart does not intentionally pull newer moving tags.

Refresh/recreate selected services with::

   lds rebuild nginx
   lds rebuild nginx runner

With no arguments, ``lds rebuild`` presents an interactive service selector.
``lds rebuild all`` resolves all active Compose services.

For locally built runtime services, normal Docker build cache is preserved while
``--pull`` refreshes the selected base.

For published images, LocalDevStack removes the selected local image, pulls the resolved
service image, recreates it, and then reboots the effective stack.

Legacy Network Migration
------------------------

Older LocalDevStack versions used fixed bridge subnets.

``lds up`` and ``lds start`` automatically check the known legacy networks before
starting. Migration only proceeds when subnet and ownership checks prove that the
network belongs to the current LocalDevStack project.

The migration uses Compose ``down --remove-orphans`` without ``-v`` and preserves named
volumes.

The old command::

   lds vpn-fix

is deprecated and no longer changes host routes/subnets.

Diagnostics
-----------

Run the main non-destructive health check::

   lds doctor

Useful targeted probes::

   lds diag dns project.localhost
   lds diag net
   lds diag tcp postgres 5432
   lds diag http https://project.localhost
   lds diag tls project.localhost

``lds sniff <url>`` is an alias for the HTTP diagnostic path.

Domain Trace
------------

Run an end-to-end domain trace::

   lds support trace project.localhost

The trace covers:

- DNS;
- TLS certificate details;
- HTTP timing/status;
- persisted Nginx upstream inference;
- recent Nginx logs.

Support Bundles
---------------

Create a shareable redacted ZIP in the current directory::

   lds support bundle

or choose an explicit path::

   lds support bundle --redact ./localdevstack-support.zip

The default bundle includes effective Compose configuration, Compose/container state,
networks, recent logs, generated Nginx/Apache vhosts where available, redacted env
files, and Tools-side network diagnostics.

Redaction is best-effort and is designed to remove common password/secret/token/API-key
fields and secret-bearing connection strings.

For the intentionally raw form::

   lds support bundle --full

``--full`` also includes scoped Docker inspect output and does not apply normal
redaction. Treat it as sensitive data.

The host ``zip`` command is required for bundle creation.

Events
------

Follow Docker events for the effective LocalDevStack Compose project::

   lds events

The default ``--since`` value is ``1h``. A custom value can be supplied::

   lds events 10m

Project Identity
----------------

The default Compose project identity is ``LocalDevStack``.

An explicit ``COMPOSE_PROJECT_NAME`` override is respected by project-scoped
diagnostics, events, bundles, and cleanup.

Cleanup
-------

Scoped cleanup requires explicit confirmation::

   lds clean --yes

It targets stopped LocalDevStack project containers, unused labelled LocalDevStack
networks, and generated ``localdevstack-php:*`` / ``localdevstack-node:*`` images.

Attempt LocalDevStack-labelled volume removal too::

   lds clean --yes --volumes

In-use volumes are left to Docker's normal safety rules.

Host-wide Docker prune is deliberately separate::

   lds clean --global --yes

With ``--global``, unrelated stopped containers, unused networks/images, and build
cache can be removed. Add ``--volumes`` only when host-wide unused-volume pruning is
also intended.

Destructive Compose Down
------------------------

Normal::

   lds down

preserves persistent data.

This requires explicit confirmation and removes Compose volumes::

   lds down --volumes --yes

Do not use that destructive form for routine upgrades.

Config Validation
-----------------

::

   lds config validate

This validates the effective Compose graph and checks scheduler files for CRLF. If Runner
is already running, LocalDevStack also asks Supervisor to validate its mounted
configuration.

Generated Compose fragments under ``configuration/compose/`` are listed when present.

Tools UI
--------

Open the terminal Tools UI (lazydocker) inside the project control plane::

   lds support ui

or use the shortcut::

   lds ui
