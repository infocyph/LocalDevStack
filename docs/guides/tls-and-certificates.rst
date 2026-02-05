TLS and Certificates
====================

LocalDevStack uses mkcert-based local TLS.

Two components are commonly involved:

- ``mkcert``: creates a local CA and issues dev certificates
- ``certify``: scans vhost configs and (re)generates certificates for all detected domains

Domain discovery
----------------

``certify`` typically scans all ``*.conf`` files under a shared vhost directory (mounted from your host).
From that, it derives domain names and generates SAN certificates.

Persistence
-----------

Persist these host-mounted directories:

- ``configuration/rootCA``: the local Root CA
- ``configuration/ssl``: generated cert/key output

After persistence, you can rebuild containers without losing trust.
