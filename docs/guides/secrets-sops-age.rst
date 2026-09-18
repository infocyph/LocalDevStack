Secrets with SOPS and Age
=========================

LocalDevStack provides the host/storage wiring for a SOPS/Age-based encrypted secrets
workflow through the trusted Tools control plane.

The goal is to keep plaintext secrets out of Git while making deliberate local
decryption available to development workflows.

Host Layout
-----------

LocalDevStack mounts these host paths into ``server-tools``:

``configuration/sops/config/``
   SOPS configuration.

``configuration/sops/global/``
   Shared encrypted/global secret material.

``configuration/sops/keys/``
   Sensitive Age/key material. Unix setup permissions restrict this directory and its
   files.

An optional external secrets repository can be mounted through ``SOP_REPO`` and is
available to Tools under its SOPS/vhost integration path.

CLI Access
----------

The LocalDevStack command::

   lds secrets <args...>

delegates directly to the Tools ``senv`` command inside the running ``server-tools``
container.

Use::

   lds tools sh

when you need to inspect the trusted Tools environment interactively before running a
manual SOPS/Age operation.

Trust Boundary
--------------

SOPS/Age processing belongs in the trusted Tools control plane, not in ordinary
database, web, or AI provider containers.

``server-tools`` already has powerful Docker access, so access to its shell and mounted
secret material should be treated as privileged workstation access.

Safety Guidelines
-----------------

- Keep Age private keys out of application repositories.
- Do not bake private keys into Docker images.
- Keep ``configuration/sops/keys/`` private.
- Prefer encrypted files in Git and decrypt only for the required local workflow.
- Review permissions after moving/copying key material.
- Do not place secret-bearing raw output into support bundles unless deliberately using
  and protecting ``--full`` output.

Unix Permissions
----------------

``lds setup permissions`` applies:

- ``0700`` to directories under ``configuration/sops/keys/``;
- ``0600`` to files under ``configuration/sops/keys/``.

This deliberately overrides the broader group-writable configuration-directory policy
for key material.
