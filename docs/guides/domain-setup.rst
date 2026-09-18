Domain Setup
============

Use the interactive domain wizard::

   lds setup domain

The wizard delegates generation to the Tools mkhost workflow while LocalDevStack
owns the surrounding Compose/profile/runtime orchestration.

Wizard Flow
-----------

The wizard collects the information needed for the selected application type, including:

1. domain name;
2. PHP or Node application type;
3. runtime version;
4. HTTP server mode where applicable;
5. HTTP/HTTPS behavior;
6. document root;
7. request/body limits;
8. optional mutual TLS settings.

Runtime Version Selection
-------------------------

Runtime selection is interactive and version-specific.

For PHP, the selected version remains the PHP_VERSION build input and produces::

   localdevstack-php:<selected-version>

For Node, the selected version/tag remains the NODE_VERSION build input and produces::

   localdevstack-node:<selected-version>

Both runtime families use Alpine variants.

Generated State
---------------

The current architecture does not write active Nginx/Apache vhosts to
configuration/nginx or configuration/apache.

Instead:

- Nginx vhosts persist in the NginxHosts named volume;
- Apache vhosts persist in the ApacheHosts named volume;
- PHP-FPM pool state persists in FPMPools;
- generated runtime Compose fragments are written under configuration/compose/.

Use::

   lds config validate

to validate the effective Compose graph and mounted scheduler configuration.

Routing
-------

LocalDevStack uses Docker DNS/service names instead of fixed bridge addresses. Generated
HTTP configuration routes to logical runtime service names or PHP-FPM sockets.

The three logical networks remain Frontend, Backend, and DataStore, but Docker chooses
their address ranges dynamically.

TLS
---

When HTTPS is selected, Tools refreshes the shared LocalDevStack certificate set. The
certificate SAN set always includes localhost, *.localhost, 127.0.0.1, and ::1 in
addition to generated domains/service-derived hosts.

This means convenience hosts such as admin.localhost, webmail.localhost, and
llm.localhost can use the same LocalDevStack trust chain.

Convenience Commands
--------------------

List active convenience URLs::

   lds urls

Open a known UI/domain::

   lds open admin
   lds open mail
   lds open db
   lds open redis
   lds open mongo
   lds open kibana
   lds open ai
   lds open project.localhost

Run diagnostics without mutating the stack::

   lds doctor
