Storage Layout
==============

LocalDevStack separates Docker-managed persistent runtime state from host-managed
configuration, exports, and logs.

Named Volumes
-------------

Important named volumes include:

``NginxHosts`` / ``ApacheHosts``
   Generated HTTP vhost configuration consumed by Nginx/Apache.

``SSLKeys`` / ``SSLRootCA``
   Runtime certificate/key material and the mkcert CA store.

``FPMPools`` / ``FPMSocks``
   Generated PHP-FPM pool configuration and runtime sockets.

``ComposerGlobal`` / ``GitConfig``
   Shared Composer/Git runtime state.

``ToolsState``
   Durable Tools control-plane state under ``/etc/share/state``, including domain/runtime
   metadata, monitor history, alert acknowledgements, and other Tools-owned state.

Database volumes
   ``PostgresStore``, ``MySQLStore``, ``MariaDBStore``, ``MongoDBStore``,
   ``RedisStore``, and ``ElasticSearchStore``.

Admin/observability volumes
   ``RedisInsightStore``, ``CloudBeaverStore``, ``KibanaStore``, and ``FilebeatStore``.

``EmailStore``
   Mailpit persistence.

``LLMModels``
   Ollama model persistence when the selected AI provider is Ollama.

``LLMFastFlowModels``
   FastFlow model persistence under ``/models`` when the selected AI provider is FastFlow.

These named volumes are intentionally stable so developer data can survive container and
image replacement.

Generated Vhost State
---------------------

Active Nginx/Apache vhosts do **not** live under host-side
``configuration/nginx``/``configuration/apache`` directories.

They are persisted in ``NginxHosts`` / ``ApacheHosts`` and are available to Tools and
the web servers through their mounted paths.

Domain listing, support traces, and support bundles all read this persisted state rather
than a stale host-side vhost directory.

Accordingly:

- ``lds domain ls`` reads persisted Nginx vhost state through ``server-tools``;
- ``lds support trace`` reads the named-volume vhost, with the running Nginx mount as a
  fallback;
- support bundles copy generated Nginx/Apache vhost state through ``server-tools``.

Host Configuration
------------------

``configuration/compose/``
   LocalDevStack-generated/runtime Compose fragments. Only YAML files are discovered.

``configuration/php/``
   User-editable PHP configuration.

``configuration/scheduler/cron-jobs/``
   Runner cron definitions.

``configuration/scheduler/supervisor/``
   Runner Supervisor definitions.

``configuration/sops/config/`` / ``configuration/sops/global/`` / ``configuration/sops/keys/``
   SOPS/Age configuration, global secret data, and sensitive key material.

``configuration/ssh/``
   Optional SSH material mounted read-only into supported Tools/runtime flows.

``configuration/ssl/``
   User-facing TLS exports from Tools. The public root CA is ``rootCA.pem``. Optional
   password-protected user mTLS artifacts may also be exported here.

``logs/``
   Host-visible service logs consumed by Runner log rotation and diagnostics.

TLS Authority
-------------

Runtime TLS state is owned by the SSLKeys / SSLRootCA volume pair:

- ``SSLKeys`` for server/client certificate material;
- ``SSLRootCA`` for the mkcert CA store.

Tools exports the public root certificate to::

   configuration/ssl/rootCA.pem

``lds certificate install`` uses that current path. Older installations using::

   configuration/rootCA/rootCA.pem

remain readable as a migration fallback.

The private CA key is not intended as a public host export.

Application Mount
-----------------

``PROJECT_DIR`` controls the application bind mount. A sibling ``application/`` directory
is the default, but absolute or relative alternatives are supported.

Local AI receives no application/project bind mount by default.

Docker Socket Boundary
----------------------

``server-tools`` and ``runner`` intentionally mount::

   /var/run/docker.sock

because their supported workflows need Docker control.

Persistent databases, admin clients, Nginx/Apache, ``llm-ollama``, and ``llm-fastflow`` do not receive the
socket by default.

``lds run --sock`` is a separate explicit opt-in for an ad-hoc container.

Permissions
-----------

On Unix-like hosts, ``lds setup permissions`` uses group-writable setgid directories for
``configuration/`` and ``logs/`` rather than broad world-writable modes.

Sensitive host directories are restricted:

- ``configuration/ssh/`` directories: ``0700``; files: ``0600``;
- ``configuration/sops/keys/`` directories: ``0700``; files: ``0600``;
- exported P12/PFX/private-key-style files under ``configuration/ssl/``: ``0600``.

Public certificate exports remain readable.

Cleanup and Data Safety
-----------------------

Normal stack shutdown does not delete named volumes::

   lds down

Explicit destructive volume removal requires confirmation::

   lds down --volumes --yes

Scoped cleanup is safer for routine maintenance::

   lds clean --yes

Adding ``--volumes`` attempts to remove LocalDevStack-labelled volumes that are not in
use::

   lds clean --yes --volumes

Host-wide Docker pruning requires the explicit ``--global`` flag and may affect unrelated
projects::

   lds clean --global --yes

Do not use destructive volume cleanup as part of a normal upgrade.
