TLS and Certificates
====================

LocalDevStack uses mkcert-based local TLS for development. Tools owns certificate
generation; Nginx, Apache, Mailpit, and runtime consumers receive only the mounts needed
by the LocalDevStack runtime contract.

Runtime TLS State
-----------------

The active runtime state is stored in Docker named volumes:

SSLRootCA
   mkcert CA store exposed to trusted LocalDevStack consumers at /etc/share/rootCA.

SSLKeys
   generated server/client certificate material exposed at /etc/mkcert where needed.

Tools automatically refreshes certificates through certify.

Public Host Export
------------------

Tools exports user-facing certificate artifacts to the host-mounted directory::

   configuration/ssl/

The public root CA is::

   configuration/ssl/rootCA.pem

lds certificate install uses this path. For upgrades, the legacy
configuration/rootCA/rootCA.pem path remains a read fallback.

The public CA export is safe to install into the host trust store. The private CA key
is not intended as a user-facing export.

Optional user mTLS export is disabled by default. When explicitly enabled in Tools,
a password-protected user P12 is exported under configuration/ssl/.

Certificate Coverage
--------------------

The generated certificate SAN set includes at least::

   localhost
   *.localhost
   127.0.0.1
   ::1

Tools also discovers generated vhost/service domains. The \*.localhost entry covers
built-in convenience endpoints such as:

- admin.localhost;
- webmail.localhost;
- db.localhost;
- ri.localhost;
- me.localhost;
- kibana.localhost;
- llm.localhost.

Installing the Root CA
----------------------

Linux/macOS where supported::

   sudo lds certificate install

Windows through Git Bash/lds.bat uses the CurrentUser root certificate store and does
not require the Unix sudo path.

After installation, restart browsers that cache trust decisions.

Uninstalling
------------

Remove the LocalDevStack trust anchor::

   sudo lds certificate uninstall

Scan/remove known legacy anchor locations too::

   sudo lds certificate uninstall --all

This removes the host trust-store entry. It does not destroy the LocalDevStack named
certificate volumes.

Mutual TLS
----------

When a domain enables mutual TLS, browser/user certificate material must be imported
separately. User-facing P12 export is intentionally opt-in and password-protected.

Internal Nginx-to-Apache mTLS material remains runtime state and is not the same as the
user-facing client certificate.

Troubleshooting
---------------

Check LocalDevStack health and TLS readiness::

   lds doctor

Inspect a domain TLS handshake::

   lds diag tls project.localhost

Regenerate/diagnose through the existing certificate commands::

   lds cert status
   lds cert regen all
   lds cert diagnose project.localhost

If the host export is missing, ensure server-tools is running and certificate
generation has completed. The current public export should appear at
configuration/ssl/rootCA.pem.
