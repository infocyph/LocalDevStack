Storage Layout
==============

To keep LocalDevStack reproducible, generated artifacts should be persisted on the host and mounted into containers.

Recommended host folders
------------------------

This repository uses a ``configuration/`` root (mounted into the stack):

- ``configuration/nginx``: Nginx vhost configs
- ``configuration/apache``: Apache vhost configs (only if Apache mode is used)
- ``configuration/ssl``: generated certificates (mkcert output)
- ``configuration/rootCA``: mkcert Root CA store
- ``configuration/php``: PHP runtime ini overrides
- ``configuration/ssh``: optional SSH mount (e.g., for Node deps or private repos)

Why this matters
----------------

- Keeping vhosts stable keeps cert generation stable.
- Persisting Root CA avoids repeated trust resets.
- Persisting ``php.ini`` overrides keeps runtime behavior consistent between rebuilds.
