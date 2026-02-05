Domain Setup
============

LocalDevStack creates domains and vhosts, when you run ``lds setup domain``.

How ``lds setup domain`` works
------------------------------

1. Run the interactive wizard.
2. Enable the selected profiles.
3. Bring the stack up and reload HTTP.

Wizard flow (what the user answers)
-----------------------------------

``lds setup domain`` runs an interactive 8-step flow:

1. Domain name
2. App type (PHP or NodeJs)
3. Runtime version (PHP Major.Minor, or Node major/tags)
4. Server type (PHP: Nginx or Apache; Node: Nginx forced + optional Node start command)
5. Protocol (HTTP only / HTTPS only / both + optional redirect)
6. Document root (relative path mapped under ``/app``)
7. Client max body size
8. Mutual TLS toggle (only available when HTTPS is enabled; this requires client side certificate)

What it generates
-------------------------

Vhost configs
~~~~~~~~~~~~~~~~~~

Writes generated vhost files:

- Nginx vhost:
  ``configuration/nginx/<domain>.conf``

- Apache vhost (only when Apache mode is selected):
  ``configuration/apache/<domain>.conf``

TLS handling (HTTPS)
~~~~~~~~~~~~~~~~~~~~

If you select HTTPS in the wizard, after writing the HTTPS config;
this generates/refreshes certificates for all known hosts.

See: :doc:`tls-and-certificates`

Node apps (optional)
~~~~~~~~~~~~~~~~~~~~

If you choose **NodeJs** app type:

- It generates a Node compose fragment:

  ``docker/extras/<token>.yaml``

The token is derived from the domain (slugified).
This compose fragment defines a Node service (internal port is always ``3000``) and sets a profile like:

- ``node_<token>``

Tips
----

- Prefer a consistent domain scheme (e.g., ``project.localhost``) so your routing stays predictable.
- After any vhost/cert changes, ``lds`` will run ``lds http reload`` automatically as part of setup;
  you can also run it manually when you edit configs yourself.
