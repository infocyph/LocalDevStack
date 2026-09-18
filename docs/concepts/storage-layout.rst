Storage Layout
==============

LocalDevStack deliberately separates Docker-managed runtime state from host-managed
configuration and exports.

Named Volumes
-------------

Important named volumes include:

NginxHosts / ApacheHosts
   Generated HTTP vhost configuration consumed by Nginx/Apache.

SSLKeys / SSLRootCA
   Runtime certificate/key material and the mkcert CA store.

FPMPools / FPMSocks
   Generated PHP-FPM pool configuration and runtime sockets.

ComposerGlobal / GitConfig
   Shared runtime state for Composer and Git integration.

Database/admin volumes
   Persistent PostgreSQL, MySQL, MariaDB, MongoDB, Redis, Elasticsearch, Kibana,
   RedisInsight, CloudBeaver, and Filebeat state.

EmailStore
   Mailpit persistence.

LLMModels
   Ollama/local-model persistence when the ai profile is enabled.

Named volumes are intentionally not renamed during this integration release so existing
developer data can survive upgrades.

Host Configuration
------------------

configuration/compose/
   LocalDevStack-generated runtime Compose fragments. The CLI discovers only YAML files
   in this directory and validates the effective Compose graph before use.

configuration/php/
   User-editable PHP configuration. Normal updates must not overwrite user customizations.

configuration/scheduler/cron-jobs/
   Runner cron definitions.

configuration/scheduler/supervisor/
   Runner Supervisor definitions.

configuration/sops/config/
configuration/sops/global/
configuration/sops/keys/
   SOPS/Age configuration and sensitive key material.

configuration/ssh/
   Optional SSH material mounted read-only into supported runtime/tool flows.

configuration/ssl/
   User-facing TLS exports from Tools. The public root CA is exported here as
   rootCA.pem. Optional password-protected mTLS user artifacts may also appear here.

logs/
   Host-visible service logs consumed by Runner log rotation and diagnostics.

TLS Authority
-------------

Runtime TLS state is owned by the named volumes:

- SSLKeys for server/client certificate material;
- SSLRootCA for the mkcert CA store.

Tools exports the public root certificate to::

   configuration/ssl/rootCA.pem

lds certificate install uses that current path. Older installations using
configuration/rootCA/rootCA.pem remain readable as a migration fallback.

The private CA key is not intended as a public host export.

Permissions
-----------

On Unix-like hosts, lds setup permissions uses group-writable setgid directories
for configuration/ and logs/ rather than broad world-writable 777 modes.

Sensitive host directories are restricted:

- configuration/ssh/ directories: 0700; files: 0600;
- configuration/sops/keys/ directories: 0700; files: 0600.

Windows keeps its platform-specific wrapper/permission behavior.

Project Mount
-------------

PROJECT_DIR controls the application bind mount. A common layout is a sibling
application/ directory, but absolute or relative alternatives are supported.

Local AI receives no application/project bind mount by default.
