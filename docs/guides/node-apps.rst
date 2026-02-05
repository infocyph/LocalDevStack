Node Apps
=========

LocalDevStack supports Node applications behind Nginx reverse proxy.

Common model
------------

- Nginx terminates HTTP/HTTPS
- Nginx proxies to the Node container (e.g., port 3000)
- Node app source is mounted under ``/app``

Vhost generation
----------------

When you choose a Node app in the domain wizard, the Tools container can generate:

- a domain-specific Nginx vhost
- a compose fragment describing the Node service

Health checks
-------------

Node services are typically checked via a simple TCP connect probe.
