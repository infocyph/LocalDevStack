Databases and Admin Clients
===========================

Database services are profile-driven and communicate through Docker DNS names. Applications
inside LocalDevStack should use service names rather than container IP addresses.

Service Map
-----------

.. list-table::
   :header-rows: 1
   :widths: 18 18 24 24

   * - Profile
     - Service DNS
     - Admin client
     - Convenience URL
   * - ``postgresql``
     - ``postgres``
     - CloudBeaver
     - ``https://db.localhost``
   * - ``mysql``
     - ``mysql``
     - CloudBeaver
     - ``https://db.localhost``
   * - ``mariadb``
     - ``mariadb``
     - CloudBeaver
     - ``https://db.localhost``
   * - ``mongodb``
     - ``mongodb``
     - Mongo Express
     - ``https://me.localhost``
   * - ``redis``
     - ``redis``
     - RedisInsight
     - ``https://ri.localhost``
   * - ``elasticsearch``
     - ``elasticsearch``
     - Kibana
     - ``https://kibana.localhost``

Enable services through::

   lds setup profile

or manage profiles manually::

   lds profiles add postgresql redis
   lds profiles remove redis

Persistence
-----------

Each primary datastore has a stable named volume:

- PostgreSQL: ``PostgresStore``;
- MySQL: ``MySQLStore``;
- MariaDB: ``MariaDBStore``;
- MongoDB: ``MongoDBStore``;
- Redis: ``RedisStore``;
- Elasticsearch: ``ElasticSearchStore``.

Admin/observability state is persisted separately where the upstream application needs
it.

Connection Settings
-------------------

The guided profile flow writes service settings to ``docker/.env``.

Important keys include:

PostgreSQL
   ``POSTGRES_VERSION``, ``POSTGRES_USER``, ``POSTGRES_PASSWORD``,
   ``POSTGRES_DATABASE``.

MySQL
   ``MYSQL_VERSION``, ``MYSQL_ROOT_PASSWORD``, ``MYSQL_USER``, ``MYSQL_PASSWORD``,
   ``MYSQL_DATABASE``.

MariaDB
   ``MARIADB_VERSION``, ``MARIADB_ROOT_PASSWORD``, ``MARIADB_USER``,
   ``MARIADB_PASSWORD``, ``MARIADB_DATABASE``.

MongoDB
   ``MONGODB_VERSION``, ``MONGODB_ROOT_USERNAME``, ``MONGODB_ROOT_PASSWORD``.

Redis
   ``REDIS_VERSION``.

Elasticsearch
   ``ELASTICSEARCH_VERSION``. The same version is used for Elasticsearch, Kibana, and
   Filebeat so the Elastic stack stays aligned.

The wizard defaults are intended for local development convenience. Change credentials
when a project or workstation policy requires stronger local isolation.

CLI Wrappers
------------

LocalDevStack includes short wrappers so host commands can be routed into the relevant
service/runtime.

PostgreSQL::

   lds pg ...
   lds psql ...
   lds pg_dump ...
   lds pg_restore ...

MySQL::

   lds my ...
   lds mysql ...
   lds mysqldump ...

MariaDB::

   lds maria ...
   lds mariadb ...
   lds mariadb-dump ...

Redis::

   lds redis ...
   lds redis-cli ...

MongoDB::

   lds mongo ...
   lds mongosh ...
   lds mongoimport ...
   lds mongoexport ...

Elasticsearch::

   lds es ...
   lds elasticsearch ...

The wrappers preserve the service-name based architecture and avoid depending on fixed
bridge addresses.

Health and Dependencies
-----------------------

Databases use local readiness probes. Related admin clients wait for their dependency
where the Compose contract declares a health condition.

Check the whole stack with::

   lds doctor

Inspect a service directly with::

   lds logs postgres
   lds shell service:postgres
   lds restart postgres

The older ``lds stack exec postgres`` form remains available for service-only
compatibility.

Admin UIs
---------

Use::

   lds urls

to show only convenience endpoints whose related profile is enabled.

Open them directly with::

   lds open db
   lds open redis
   lds open mongo
   lds open kibana

Filebeat
--------

An advanced ``filebeat`` Compose profile is available for Elastic log ingestion. It is
not included in the normal guided catalog.

Enable it deliberately alongside Elasticsearch, for example::

   lds profiles add elasticsearch filebeat

Filebeat reads the shared host log tree read-only and sends to the ``elasticsearch``
service over Docker DNS.
