Quickstart
==========

This quickstart is intentionally short. It gets you running with a basic HTTP + runtime stack, then points you to the
guides for domains, TLS, Node, secrets, and notifications.

Prerequisites
-------------

- Docker (Docker Engine recommended; Docker Desktop is fine)

Typical flow
------------

1. Configure profiles (what services to run).
2. Start the stack.
3. Add a domain + vhost config.
4. (Optional) Generate and trust TLS certificates.
5. Reload HTTP services.

Next steps
----------

- Domain and vhosts: :doc:`guides/domain-setup`
- Local TLS (mkcert + certify): :doc:`guides/tls-and-certificates`
- Node apps behind Nginx: :doc:`guides/node-apps`
- Encrypted secrets (SOPS + Age): :doc:`guides/secrets-sops-age`
- Notifications: :doc:`guides/notifications`
