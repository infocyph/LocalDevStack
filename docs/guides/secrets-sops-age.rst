Secrets with SOPS and Age
=========================

LocalDevStack can integrate an encrypted secrets workflow using **SOPS** and **Age**.

The goal is simple:

- Keep ``.env``-like secrets encrypted in Git
- Decrypt only when needed (locally) into runtime containers or build steps

Typical workflow (high level)
-----------------------------

1. Store secrets as ``*.enc.env`` (or similar) in a repo.
2. Keep Age private keys outside the repo (mounted into Tools container).
3. Use a helper (often called ``senv``) to decrypt into a target env file.

Safety notes
------------

- Prefer read-only mounts for secrets repos.
- Do not bake private keys into images.
