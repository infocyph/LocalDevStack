CLI Reference
=============

``lds`` is the canonical LocalDevStack host CLI. ``lds.bat`` bridges Windows/Git Bash
invocation into the same command surface.

Global Options
--------------

``-v`` / ``--verbose``
   Enable verbose command/error output.

``-q`` / ``--quiet``
   Suppress non-error LocalDevStack output where supported.

``--reload-extras``
   Force a rescan of ``configuration/compose/*.yaml`` / ``*.yml`` before the command.

``-h`` / ``--help``
   Show help.

The machine-copyable Markdown command summary is::

   lds help --markdown

Stack
-----

::

   lds stack up
   lds stack start
   lds stack down [--volumes --yes]
   lds stack restart [service...]
   lds stack status [status-args...]
   lds stack ps
   lds stack logs [service] [--follow] [--since <duration>] [--grep <pattern>]
   lds stack exec <service> [command...]
   lds stack events [since]
   lds stack clean --yes [--volumes] [--global]
   lds stack diff [--config] [--json]
   lds stack config <show|services|profiles|env-used|validate>
   lds stack http reload

Common top-level aliases are::

   lds up
   lds start
   lds down
   lds stop
   lds restart
   lds reboot
   lds status
   lds ps
   lds logs
   lds exec
   lds events
   lds clean
   lds config

Domains
-------

::

   lds domain add
   lds domain rm [args...]
   lds domain ls

Legacy aliases::

   lds host add
   lds host rm
   lds host list

Setup
-----

::

   lds setup init
   lds setup permissions
   lds setup domain
   lds setup profile
   lds setup profiles

Profiles
--------

::

   lds profiles list
   lds profiles add <profile...>
   lds profiles remove <profile...>

Configuration
-------------

::

   lds config show [--json] [--raw]
   lds config services
   lds config profiles
   lds config env-used
   lds config validate
   lds images
   lds urls

``config show`` is redacted by default.

Certificates
------------

Tools certificate operations::

   lds cert status [domain|all]
   lds cert regen [domain|all] [--yes]
   lds cert diagnose <domain>

Host trust-store operations::

   lds certificate install
   lds certificate uninstall [--all]

Diagnostics
-----------

::

   lds doctor
   lds diag dns <domain>
   lds diag net
   lds diag tcp <host> <port>
   lds diag http <url> [curl-args...]
   lds diag tls <domain>
   lds sniff <url> [curl-args...]

``sniff`` is the HTTP diagnostic shortcut.

Support
-------

::

   lds support open <admin|mail|db|redis|mongo|kibana|ai|domain>
   lds support trace <domain>
   lds support bundle [--redact|--full] [output.zip]
   lds support notify <watch|test> ...
   lds support ui

Shortcuts::

   lds open ...
   lds bundle ...
   lds notify ...
   lds ui

Tools Control Plane
-------------------

::

   lds tools sh
   lds tools exec "<command>"
   lds tools file <path>

Open a generic container shell or run a command::

   lds cli <container>
   lds cli <container> <command...>

Resolve a domain/container to its application shell::

   lds core [domain|container]

Secrets
-------

::

   lds secrets <senv-args...>

This delegates to Tools ``senv``.

AI Consumer
-----------

::

   lds ai status
   lds ai ask ...
   lds ai explain ...
   lds ai troubleshoot ...
   lds ai review ...
   lds ai repo-review ...
   lds ai graphify ...

``status`` maps to the Tools provider-status flow.

Host Graphify Workflow
----------------------

::

   lds graphify
   lds graphify ./your-project
   lds graphify ./your-project --mode deep --token-budget 4000 --max-concurrency 1

This command runs the host ``graphify`` CLI against LocalDevStack's Ollama provider.
It performs ``extract --backend ollama --no-cluster`` followed by
``cluster-only <same-path> --backend ollama``, so clustering happens once.

By default it derives:

- ``OLLAMA_BASE_URL=http://llm-ollama.localhost:11434/v1``, routed through Nginx;
- ``OLLAMA_MODEL`` from ``LDS_AI_MODEL``;
- ``GRAPHIFY_API_TIMEOUT`` from ``LDS_AI_TIMEOUT``.

The stack and AI profile must be running; there is no separate host-port setup step.

An explicitly supplied ``OLLAMA_BASE_URL`` overrides the default
``http://llm-ollama.localhost:11434/v1`` endpoint.

LLM Provider
------------

::

   lds llm models
   lds llm ps
   lds llm show ...
   lds llm pull ...
   lds llm rm ...
   lds llm unload ...
   lds llm run ...
   lds llm ask ...
   lds llm chat ...
   lds llm prompt ...
   lds llm code ...
   lds llm review ...
   lds llm json ...
   lds llm ai-commit ...
   lds llm ollama ...
   lds llm api ...
   lds llm version
   lds llm help

These commands execute the bundled provider CLI through LocalDevStack's Compose wrapper.
Do not replace them with bare ``docker compose exec llm-ollama ...`` from the repository
root; LocalDevStack has no root ``compose.yml``.

``LDS_AI_MODEL`` is forwarded to the provider as ``LLM_OLLAMA_MODEL``, so
``lds ai`` and ``lds llm`` share the configured default model. Provider input,
attachment, PDF and Ollama runtime knobs are documented in :doc:`../guides/local-ai`.

Runtime selection::

   lds llm runtime
   lds llm runtime <cpu|nvidia|amd>

The runtime command keeps the derived image tag in sync and also refreshes
``LDS_AI_IGPU_ENABLE``. AMD runtime on an AMD CPU uses ``1`` so Ollama admits the
integrated Radeon GPU; the other derived cases use ``0``.

Native Ollama access is always routed through Nginx at
``http://llm-ollama.localhost:11434``; the provider container itself is not
published directly.

Rebuild
-------

::

   lds rebuild
   lds rebuild all
   lds rebuild <service...>

No-argument rebuild uses an interactive selector.

Ad-hoc Dockerfile Runner
------------------------

::

   lds run
   lds run shell
   lds run ps
   lds run logs
   lds run stop
   lds run rm
   lds run open

Useful flags include::

   --name <name>
   --tag <tag>
   --no-build
   --no-keepalive
   --sock
   --host-os <value>
   --publish <host:container>
   -p <host:container>
   --mount <host[:container]>
   --port <container-port>
   --path <url-path>
   --http
   --https

See :doc:`../guides/ad-hoc-runner`.

Runtime and Client Wrappers
---------------------------

PHP/Node::

   lds php ...
   lds composer ...
   lds node ...
   lds npm ...
   lds npx ...

PostgreSQL::

   lds pg ...
   lds psql ...
   lds pg_dump ...
   lds pg_restore ...

MySQL::

   lds my ...
   lds mysql ...
   lds mysqldump ...

MariaDB::

   lds maria ...
   lds mariadb ...
   lds mariadb-dump ...

Redis::

   lds redis ...
   lds redis-cli ...

MongoDB::

   lds mongo ...
   lds mongodb ...
   lds mongosh ...
   lds mongoimport ...
   lds mongoexport ...

Elasticsearch::

   lds es ...
   lds elastic ...
   lds elasticsearch ...

Unknown Command Fallback
------------------------

If a command is not implemented by ``lds`` itself, LocalDevStack delegates it to
``bin/tool-runner``. This preserves the existing Tools/Toolset command extension surface.

Deprecated
----------

::

   lds vpn-fix

The command now explains that fixed-subnet manipulation is obsolete because networking
is dynamically assigned.
