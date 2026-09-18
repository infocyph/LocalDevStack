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

Infrastructure image overrides include::

   LDS_TOOLS_IMAGE=infocyph/tools:latest
   LDS_RUNNER_IMAGE=infocyph/runner:latest
   LDS_NGINX_IMAGE=infocyph/nginx:latest
   LDS_APACHE_IMAGE=infocyph/apache:latest

The moving values above are release defaults; normal users usually leave them in
``docker/release.env`` rather than copying them to ``docker/.env``.

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
- Standard local AI uses ``infocyph/llm-sm:latest``.
- AMD local AI uses ``infocyph/llm-sm:amd-latest``.
- Elasticsearch, Kibana, and Filebeat stay on one aligned version.

Run::

   lds images

to inspect the effective image set after release defaults and user/shell overrides.

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
   LDS_AI_URL=http://llm-sm:11434
   LDS_AI_MODEL=qwen2.5:3b
   LDS_AI_RUNTIME=cpu
   LDS_LLM_HOST_PORT=0

Use::

   lds llm runtime <cpu|nvidia|amd>
   lds llm host-port <status|on|off>

instead of editing the corresponding runtime flags manually in normal workflows.

Tools also accepts optional timeout/context limits through ``LDS_AI_CONNECT_TIMEOUT``,
``LDS_AI_PREFLIGHT_TIMEOUT``, ``LDS_AI_TIMEOUT``, ``LDS_AI_AVAILABILITY_TTL``,
``LDS_AI_MAX_CONTEXT_BYTES``, ``LDS_AI_MAX_REQUEST_BYTES``, and
``LDS_AI_MAX_RESPONSE_BYTES``.

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
