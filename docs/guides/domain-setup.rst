Domain Setup
============

Most users create domains and vhosts through the Tools container (``mkhost``).

What ``mkhost`` typically does
------------------------------

- Generates Nginx vhost config for your domain.
- Generates Apache vhost config when Apache mode is enabled.
- Generates a Node compose fragment when you choose a Node app.
- Optionally triggers certificate generation workflow (see :doc:`tls-and-certificates`).

Tips
----

- Keep vhost configs under ``configuration/nginx`` / ``configuration/apache``.
- Prefer a consistent domain scheme (e.g., ``project.localhost``) for easy routing.
