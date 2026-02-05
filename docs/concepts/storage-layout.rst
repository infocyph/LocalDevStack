Storage Layout
==============

To keep LocalDevStack reproducible, generated artifacts are persisted on the host and mounted into containers.

Directories
------------------------

LocalDevStack uses a ``configuration/`` root (mounted into the stack). Keep all user-managed and generated
artifacts here:

- ``configuration/nginx``: Nginx host configs (primary entry in most setups)
- ``configuration/apache``: Apache host configs (only if Apache mode is enabled)
- ``configuration/ssl``: generated certificates
- ``configuration/rootCA``: Root CA store (persist this to keep browser trust stable, see :doc:`tls-and-certificates`.)
- ``configuration/php``: PHP runtime ini overrides (e.g., ``php.ini``)
- ``configuration/ssh``: optional SSH mount (useful for private repos, git over SSH or tooling)
- ``configuration/sops``: optional SOPS/Age keys + config (if you use the secrets workflow)

Why this matters
----------------

- Keeping hosts stable keeps host and certificate generation stable.
- Persisting the Root CA avoids repeated trust resets and browser warnings.
- Persisting ``php.ini`` overrides keeps runtime behavior consistent between rebuilds.
- Persisting SOPS/Age configuration avoids re-creating keys and keeps secrets workflows predictable.
