server-tools Image
==================

Purpose
-------

The ``server-tools`` image acts as LocalDevStack's control plane:

- Domain/vhost generation (e.g., ``mkhost`` / ``delhost``)
- TLS automation (mkcert + ``certify``)
- Secrets helpers (SOPS + Age wrappers)
- Optional notification utilities

How it fits
-----------

LocalDevStack mounts shared folders (vhosts, ssl, rootCA, etc.) into the Tools container so that generated artifacts
are persisted on the host and visible to the HTTP containers.
