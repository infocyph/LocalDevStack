Profiles and Environment
========================

LocalDevStack uses Docker Compose **profiles** so you can enable only the services you want for a given project.

Setting up Environment usable by Your Projects
----------------------

- Use root ``.env`` (project-level overrides)
- These are common & directly shared to projects you host
- If you want project specific only a single project you need to handle that inside your project

Guided setup for on demands services (DB, Cache)
------------

The ``lds`` CLI typically includes helpers like:

- ``lds setup profiles``

These helpers are opinionated: they try to keep profiles and generated configs consistent.

Manual setup (Don't use unless you are fully aware of internals)
------------

Enable PHP 8.4 + MariaDB + Redis:

.. code-block:: none

   COMPOSE_PROFILES=php84,mariadb,redis

Enable Apache mode (Nginx -> Apache -> PHP-FPM):

.. code-block:: none

   COMPOSE_PROFILES=apache,php84

These are just some of the samples.
