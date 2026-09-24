Domain Setup
============

LocalDevStack uses Tools for domain/vhost generation while the host ``lds`` CLI owns the
surrounding profile, Compose, and runtime orchestration.

Create a Domain
---------------

Start the stack first so ``server-tools`` is available::

   lds up

Then run the interactive wizard::

   lds setup domain

or the canonical domain command::

   lds domain add

The wizard delegates to Tools ``mkhost`` and collects the details needed for the chosen
application type, including:

1. domain name;
2. PHP, Node, or supported static/backend application type;
3. runtime version where applicable;
4. HTTP server path where applicable;
5. HTTP/HTTPS behavior;
6. document root;
7. request/body limits;
8. optional mutual TLS settings.

After generation, LocalDevStack reads Tools state, adds any required generated
server/runtime profile, clears temporary mkhost state, and recreates the stack.

Runtime Version Selection
-------------------------

Runtime selection remains explicit and version-specific.

For PHP, the selected version produces::

   localdevstack-php:<selected-version>

For Node, the selected version produces::

   localdevstack-node:<selected-version>

Both runtime families use Alpine variants. The version selector is intentionally not
replaced by the moving infrastructure-image policy.

Generated State
---------------

Active vhosts are Docker-managed state:

- Nginx vhosts persist in ``NginxHosts``;
- Apache vhosts persist in ``ApacheHosts``;
- PHP-FPM pool state persists in ``FPMPools``;
- PHP-FPM sockets use ``FPMSocks``;
- generated runtime Compose fragments are written under configuration/compose/.

There is no active host-side ``configuration/nginx`` source of truth.

List Domains
------------

List persisted Nginx domains::

   lds domain ls

Domain listing reads the NginxHosts named volume through ``server-tools``.

Remove a Domain
---------------

Use::

   lds domain rm

or pass arguments supported by the underlying Tools removal flow::

   lds domain rm <args...>

LocalDevStack delegates removal to Tools ``rmhost``, removes any generated server profile
reported by that operation, resets temporary removal state, and recreates the stack.

The legacy command group remains available::

   lds host add
   lds host rm
   lds host list

but ``domain`` is the canonical interface.

Routing
-------

LocalDevStack uses Docker DNS/service names instead of fixed bridge addresses. Generated
HTTP configuration routes to logical runtime service names or PHP-FPM sockets.

Nginx is always the host-facing front door. Apache is always available as an alternate
backend for domains that choose that mode.

The three logical networks remain ``Frontend``, ``Backend``, and ``DataStore`` while
Docker chooses their address ranges dynamically.

TLS
---

When HTTPS is selected, Tools refreshes the shared LocalDevStack certificate set.

The certificate SAN set includes at least::

   localhost
   *.localhost
   127.0.0.1
   ::1

and Tools can include generated domain/service names.

The wildcard covers built-in convenience endpoints such as ``admin.localhost``,
``webmail.localhost``, and ``llm-ollama.localhost``.

Working in a Domain or Application Context
------------------------------------------

Use the canonical shell navigator to resolve a discovered domain to its
application/runtime container and working directory::

   lds shell project.localhost

Run a command in that same resolved application context without losing argv boundaries::

   lds shell project.localhost -- php artisan about

With no target, ``lds shell`` opens the grouped selector and includes discovered
domains, direct application directories under ``server-tools:/app``, services,
containers, and Tools.

Use qualified selectors when you want a specific target class or a name is ambiguous::

   lds shell domain:project.localhost
   lds shell app:project
   lds shell service:php84
   lds shell container:localdevstack-php84-1

``lds core`` and ``lds cli`` remain compatibility commands, but new workflows
should use ``lds shell``.

Diagnostics
-----------

Validate the effective stack::

   lds config validate

Inspect a domain end to end::

   lds support trace project.localhost

The trace checks DNS, TLS, HTTP timing, generated Nginx upstream configuration, and
recent Nginx logs.

Additional probes include::

   lds diag dns project.localhost
   lds diag tls project.localhost
   lds diag http https://project.localhost

Convenience Commands
--------------------

List active built-in URLs::

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
