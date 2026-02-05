Profiles and Environment
========================

LocalDevStack uses Docker Compose **profiles** so you can enable only the services you want for a given project.

Where profiles are set
----------------------

- Primary: ``docker/.env`` (this repo)
- Optional: root ``.env`` (project-level overrides)

The key variable is typically:

- ``COMPOSE_PROFILES``: comma-separated profile list

Examples
--------

Enable Nginx + PHP 8.4 + tools + MariaDB + Redis:

.. code-block:: none

   COMPOSE_PROFILES=nginx,php,php84,tools,mariadb,redis

Enable Apache mode (Nginx -> Apache -> PHP-FPM):

.. code-block:: none

   COMPOSE_PROFILES=nginx,apache,php,php84,tools

Guided setup
------------

The ``server`` CLI typically includes helpers like:

- ``server setup profiles``
- ``server setup domain``

These helpers are opinionated: they try to keep profiles and generated configs consistent.
