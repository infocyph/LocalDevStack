Architecture
============

LocalDevStack is composed of:

- The **orchestrator**: ``server`` / ``server.bat`` (selects profiles, runs Compose, common workflows)
- The **HTTP layer**: Nginx (front proxy) and optionally Apache (backend HTTP) depending on your stack choice
- The **runtimes**: PHP (FPM) and Node (and future stacks)
- The **control plane**: the **server-tools** image (domain/vhost generation, TLS automation, secrets helpers)
- The **runner**: supervisord + cron + logrotate and helper exec wrappers

Key idea
--------

Instead of a monolithic "one container does everything" model, LocalDevStack uses:

- Compose profiles to enable only what you need
- Generated configuration artifacts (vhosts, certificates) persisted on the host
- Stable container names/hostnames to keep local routing predictable

How containers cooperate
------------------------

1. You generate or edit vhost configs (usually via ``mkhost`` in the Tools container).
2. The Tools container can scan all vhosts and generate certificates (``certify`` + ``mkcert``).
3. Nginx loads vhosts and routes requests either:

   - directly to PHP-FPM (fastcgi), or
   - to Apache (reverse proxy) when Apache mode is enabled, or
   - to a Node service (reverse proxy).

4. The Runner handles background services (cron/logrotate) and gives you a consistent place for helper utilities.
