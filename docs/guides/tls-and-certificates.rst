TLS and Certificates
====================

LocalDevStack uses mkcert-based local TLS for development. Tools owns certificate
generation; the host ``lds`` CLI owns trust-store installation/removal.

Runtime TLS State
-----------------

The active runtime state is stored in Docker named volumes:

``SSLRootCA``
   mkcert CA store exposed to trusted LocalDevStack consumers at
   ``/etc/share/rootCA``.

``SSLKeys``
   Generated server/client certificate material exposed at ``/etc/mkcert`` where
   needed.

Tools refreshes certificates through its ``certify`` command family.

Public Host Export
------------------

Tools exports user-facing certificate artifacts to::

   configuration/ssl/

The public root CA is::

   configuration/ssl/rootCA.pem

For upgrades, the legacy path remains a read fallback::

   configuration/rootCA/rootCA.pem

The public CA certificate is safe to install into the host trust store. The private CA
key is not intended as a public export.

Optional password-protected user mTLS artifacts may also be exported under
``configuration/ssl/``.

Certificate Coverage
--------------------

The generated SAN set includes at least::

   localhost
   *.localhost
   127.0.0.1
   ::1

Tools can also discover generated vhost/service domains.

The wildcard covers built-in endpoints such as:

- ``admin.localhost``;
- ``webmail.localhost``;
- ``db.localhost``;
- ``ri.localhost``;
- ``me.localhost``;
- ``kibana.localhost``;
- ``llm.localhost``.

Install the Root CA
-------------------

Linux::

   sudo lds certificate install

The installer detects common Linux families and uses their normal trust-store location/
refresh mechanism where available:

- Debian/Ubuntu-style ``update-ca-certificates``;
- RHEL/Fedora-style ``update-ca-trust``;
- Arch-style p11-kit/trust handling.

When ``certutil`` is available, the invoking user's NSS database is also updated on
supported Unix flows.

Windows/Git Bash::

   lds.bat certificate install

Windows imports the CA into ``CurrentUser\\Root`` through PowerShell.

macOS
   LocalDevStack can run through Docker Desktop, but automatic macOS Keychain import is
   not currently implemented by the host installer. Trust
   ``configuration/ssl/rootCA.pem`` manually in Keychain when required.

Restart browsers that cache trust results after changing the CA.

Uninstalling
------------

Linux::

   sudo lds certificate uninstall

Scan/remove all known LocalDevStack anchor locations too::

   sudo lds certificate uninstall --all

Windows/Git Bash::

   lds.bat certificate uninstall

The uninstall operation removes the host trust anchor. It does not delete the
``SSLRootCA`` / ``SSLKeys`` Docker volumes.

Tools Certificate Commands
--------------------------

The Tools certificate workflow is exposed separately through::

   lds cert status
   lds cert regen all
   lds cert diagnose project.localhost

``lds certificate ...`` manages host trust; ``lds cert ...`` delegates certificate
generation/status/diagnostics to Tools.

Mutual TLS
----------

When a domain enables mutual TLS, browser/user certificate material must be imported
separately. User-facing P12/PFX exports are intentionally opt-in and password-protected.

Internal Nginx-to-Apache mTLS material remains runtime state and is not the same as a
user-facing browser certificate.

Permissions
-----------

``lds setup permissions`` keeps public CA exports readable while applying restrictive
permissions to exported private-key-style files (including P12/PFX/key artifacts).

Troubleshooting
---------------

Check TLS readiness::

   lds doctor

Inspect a domain handshake::

   lds diag tls project.localhost

Run the end-to-end trace::

   lds support trace project.localhost

If the public export is missing, ensure ``server-tools`` is running and certificate
generation has completed. The current export should appear at
``configuration/ssl/rootCA.pem``.
