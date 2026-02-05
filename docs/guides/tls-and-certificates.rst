TLS and Certificates
====================

LocalDevStack uses **mkcert-based local TLS** for development.

At first run, it creates a **local Root CA** and issues development certificates.
After that, it scans your vhost configs and (re)generates certificates for all detected domains.

Certificates are generated and persisted under the host-mounted ``configuration/`` tree so they survive rebuilds.

Generated files (host)
----------------------

LocalDevStack persists TLS artifacts in this layout::

  configuration/
  ├── rootCA
  │   ├── rootCA-key.pem
  │   └── rootCA.pem
  └── ssl
      ├── apache-client-key.pem
      ├── apache-client.pem
      ├── apache-server-key.pem
      ├── apache-server.pem
      ├── local-key.pem
      ├── local.pem
      ├── nginx-client-key.pem
      ├── nginx-client.p12
      ├── nginx-client.pem
      ├── nginx-proxy-key.pem
      ├── nginx-proxy.pem
      ├── nginx-server-key.pem
      └── nginx-server.pem

Notes:

- ``configuration/rootCA/rootCA.pem`` is your local development CA certificate.
- The ``*-server*.pem`` pairs are used by Nginx/Apache for HTTPS.
- The ``*-client*.pem`` pairs are used when **mutual TLS** is enabled for a domain.
- ``nginx-client.p12`` is provided for convenient browser import when mutual TLS is enabled.

Domain discovery
----------------

Certificate generation scans all ``*.conf`` files under the shared vhost directory (mounted from your host).
From those filenames/configs, LocalDevStack derives domain names and generates SAN certificates
covering all detected domains.

This keeps certs aligned with your active vhost set: add/remove a domain, regenerate, done.

Trusting the Root CA
--------------------

To trust your local CA on your host system, run::

  sudo lds certificate install

This installs ``configuration/rootCA/rootCA.pem`` into your OS trust store (where supported).

Manual install is also possible:

- Import ``configuration/rootCA/rootCA.pem`` into your OS trust store using your system UI/tools.
- This is useful in locked-down environments where automated install is restricted.

Mutual TLS (Client certificates)
--------------------------------

If you enable **mutual TLS** for any domain:

- You must install the client certificate in your browser.
- Recommended: import ``configuration/ssl/nginx-client.p12`` into the browser certificate store.

After importing, the browser will present the client certificate when accessing mTLS-protected domains.

Uninstalling the Root CA
------------------------

If you previously trusted the LocalDevStack Root CA and want to remove it from your system trust store, use::

  sudo lds certificate uninstall

This removes the installed CA file from the detected OS trust anchor location and then refreshes the system trust store
(best-effort).

Remove from all known locations (cleanup mode)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

If you changed distros, moved CA paths, or installed it manually in different locations, use::

  sudo lds certificate uninstall --all

This additionally scans common CA anchor locations and removes any leftover ``rootCA`` entries it finds, then refreshes
the trust store.

Notes
~~~~~

- Uninstall requires sudo/admin privileges.
- Trust store refresh is best-effort; on uncommon distributions you may need to refresh trust manually after removal.
- This only removes the *installed* OS trust anchor. It does not delete your generated CA files under
  ``configuration/rootCA`` (those are part of your project persistence).


Troubleshooting
---------------

Browser still shows “Not Secure”
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- Confirm the Root CA is trusted:

  - Run ``lds certificate install`` again, or
  - Manually install ``configuration/rootCA/rootCA.pem`` into your OS trust store.

- Restart the browser after installing the CA (some browsers cache trust decisions).

Certificate mismatch after changing domains
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- If you renamed/removed domains, regenerate certs so SANs match the current vhost set.
- Ensure the vhost files under ``configuration/nginx`` / ``configuration/apache`` reflect the current domains.

Mutual TLS enabled but browser doesn’t prompt / request fails
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- Import the client cert (recommended): ``configuration/ssl/nginx-client.p12``.
- Verify the client cert is imported into the *correct* browser profile.
- If you have multiple client certs, remove old ones and retry to avoid wrong-certificate selection.
