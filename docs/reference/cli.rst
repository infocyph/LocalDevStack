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
   lds stack exec <service> [--] [command...]
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

Execution and Shells
--------------------

``lds shell`` is the canonical execution/navigation surface.

With no arguments it builds a stable grouped catalog::

   Applications / Domains
   Application Directories
   Services
   Containers
   Utilities

The groups contain discovered domains, direct ``server-tools:/app`` child
directories, current-project Compose services, running Docker containers, and
the ``tools`` utility target::

   lds shell

The selector accepts the displayed global number or an exact name. If the same
name exists in multiple categories, use a qualified selector::

   domain:project.localhost
   app:project
   service:php84
   container:localdevstack-php84-1
   utility:tools

Explicit targets use deterministic precedence: exact discovered domain, reserved
``tools`` target, exact current-project service, exact Docker container, then an
exact direct child ``/app/<target>`` inside the current project's server-tools
container. No fuzzy matching or implicit case conversion is performed. Image
names are not implicitly instantiated.

Canonical forms::

   lds shell <target>
   lds shell <target> [--] <command> [args...]
   lds shell <target> --shell <shell-expression>
   lds shell <target> --interactive <command> [args...]

Domain targets retain application-aware working-directory behavior: Node uses
``/app``; other applications use the resolved document root when available,
then ``/app`` and ``/``. Application-directory fallback opens
``server-tools`` at ``/app/<target>``.

Normal command forms preserve argv exactly. ``--shell`` is the explicit escape
hatch for pipelines, redirections, and compound shell syntax.
``--interactive`` routes argv through the shared real-TTY execution helper.
Interactive shells and TUIs require a real TTY on both stdin and stdout; piped
commands keep stdin without forcing a TTY.

New documentation and interactive workflows should prefer ``lds shell``.
The older execution surfaces remain compatible during migration::

   lds core [domain|service|container] [--] [command...]
   lds cli <service|container> [--] [command...]
   lds stack exec <service> [--] [command...]
   lds tools sh
   lds tools exec [--] <command> [args...]
   lds tools shell-exec <shell-expression>
   lds tools file <path>

``stack exec`` remains service-only. ``tools file`` remains inspection
functionality rather than generic shell navigation.

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
   lds graphify ./your-project --mode deep --token-budget 3000 --max-concurrency 1

This command runs the host ``graphify`` CLI against the LocalDevStack LLM route.
When the docker-tools image supports docstruct, Markdown/RST/config files are extracted
mechanically and merged into Graphify after fragment validation; they are not sent through
Graphify's raw semantic LLM extractor. Other semantic formats remain Graphify-owned.

Use ``LDS_GRAPHIFY_DOCSTRUCT=off`` to force the legacy path,
``LDS_GRAPHIFY_DOCSTRUCT=on`` to require the deterministic path, and
``LDS_GRAPHIFY_DOC_REVIEW=off|auto|on`` to control bounded semantic review.
For a brand-new graph it performs a code-only ``extract --no-cluster`` first, clusters
that structural graph, then performs a normal incremental ``extract --no-cluster`` to
enrich docs/papers/images and reclusters and force-relabels the combined graph again. Existing graphs use a
single incremental extract followed by one ``cluster-only`` pass. Explicit ``--code-only``
remains a single structural build.

For the built-in local route, LocalDevStack creates a temporary Graphify provider
configuration that points directly to ``http://llm.localhost:11434/v1``. No Graphify
proxy process or Python compatibility script is used. The selected model comes from the
active provider and ``GRAPHIFY_API_TIMEOUT`` defaults from ``LDS_AI_TIMEOUT``.
Before extraction, LocalDevStack checks ``/v1/models`` and fails immediately when the
selected model is unavailable.

LLM Provider
------------

::

   lds llm provider
   lds llm runtime
   lds llm models
   lds llm pull ...
   lds llm rm ...
   lds llm run ...
   lds llm ask ...
   lds llm chat ...
   lds llm prompt ...
   lds llm code ...
   lds llm review ...
   lds llm json ...
   lds llm ai-commit ...
   lds llm api ...
   lds llm version
   lds llm help

These commands execute the active provider CLI through LocalDevStack's Compose wrapper.
Exactly one provider is active: FastFlow for XDNA2 NPU, otherwise Ollama.

Provider-specific low-level commands are guarded:

.. code-block:: text

   Ollama-only:   ps, show, unload, ollama
   FastFlow-only: validate, check, flm

Runtime selection::

   lds llm runtime auto
   lds llm runtime npu
   lds llm runtime nvidia
   lds llm runtime amd
   lds llm runtime cpu

The common Docker/API identity is ``llm:11434`` and the user-facing route is
``https://llm.localhost``. Nginx publishes the common native API loopback-only at
``http://127.0.0.1:11434``.

Generic service operations also accept ``llm`` and resolve it to the active provider::

   lds logs llm
   lds restart llm
   lds exec llm ...
   lds rebuild llm

The logical ``llm`` name is an operational alias handled by those service commands.
``lds shell service:<name>`` is intentionally exact and does not rewrite logical
service aliases. For the canonical shell navigator, target the active provider service
explicitly as ``service:llm-fastflow`` or ``service:llm-ollama``. The
``lds exec llm`` form remains the provider-neutral compatibility path.

FastFlow/NPU and Ollama both default to ``qwen3.5:9b``. Leaving ``LDS_AI_MODEL``
blank allows the provider default to apply.
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
