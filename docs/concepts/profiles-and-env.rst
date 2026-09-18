Profiles and Environment
========================

LocalDevStack uses Docker Compose profiles so optional services are selected explicitly.

Guided Profile Setup
--------------------

Use::

   lds setup profile

The host-side service catalog is tracked at::

   docker/catalog/services.psv

It describes the service/profile name, setup defaults, prompts, convenience URL,
persistent volume metadata, and supported AI runtime modes.

The current optional service profiles include:

- PostgreSQL;
- MySQL;
- MariaDB;
- MongoDB;
- Redis;
- Elasticsearch;
- local AI.

PHP and Node domain runtimes are selected separately by the domain wizard. Their
version selector is not replaced by the moving-image policy.

Environment Ownership
---------------------

Tracked product defaults live in::

   docker/release.env

User stack settings live in::

   docker/.env

The repository root .env remains project/application-facing state where applicable;
it is not the LocalDevStack release-default file.

Effective precedence is::

   built-in fallback
       < docker/release.env
       < docker/.env
       < command-scoped shell environment

LocalDevStack reads dotenv values as data. It does not blindly shell-source docker/.env.

Useful Commands
---------------

Show which environment keys are defined without printing values::

   lds config env-used

Show effective Compose config with secrets redacted::

   lds config show

Show raw effective Compose config only when intentionally needed::

   lds config show --raw

Validate Compose and mounted scheduler configuration::

   lds config validate

Show selected profiles::

   lds profiles list

Image Defaults
--------------

The default policy is:

   Prefer the moving Alpine variant when the image family provides a suitable one;
   otherwise use its normal moving latest tag.

Examples:

- PostgreSQL defaults to postgres:alpine.
- Tools, Runner, Nginx, and Apache use their published :latest aliases.
- Standard local AI uses infocyph/llm-sm:latest.
- AMD local AI uses infocyph/llm-sm:amd-latest.
- Elasticsearch, Kibana, and Filebeat stay on one aligned version because their
  stack does not provide the required moving latest contract.

Explicit user values in docker/.env or the shell override these defaults.

Runtime Version Selection
-------------------------

Tools publishes the runtime catalog used by mkhost. The user still chooses the
runtime version per domain.

PHP selection becomes:

- PHP_VERSION build input;
- localdevstack-php:<selected-version> image identity;
- Alpine PHP-FPM base.

Node selection becomes:

- NODE_VERSION build input;
- localdevstack-node:<selected-version> image identity;
- Alpine Node base.

Runtime rebuilds preserve Docker build cache while using --pull to refresh the
selected base.

Scriptomatic
------------

Runtime builds consume Scriptomatic from main by default::

   SCRIPTOMATIC_REF=main

A full 40-character commit SHA is also accepted for release/debug reproducibility.

AI Settings
-----------

Important AI settings include::

   LDS_AI_ENABLED=auto
   LDS_AI_PROVIDER=ollama
   LDS_AI_URL=http://llm-sm:11434
   LDS_AI_MODEL=qwen2.5:3b
   LDS_AI_RUNTIME=cpu
   LDS_LLM_HOST_PORT=0

Use lds llm runtime and lds llm host-port instead of editing these manually for
normal workflows.
