nginx Image
===========

Purpose
-------

The Nginx image provides the front proxy for LocalDevStack.

Typical responsibilities:

- Serve as the main entry point (80/443)
- Reverse proxy to Node services
- FastCGI to PHP-FPM when in Nginx+FPM mode
- Reverse proxy to Apache when in Nginx->Apache mode

Local routing helpers
---------------------

This image can generate an include file (e.g., ``locals.conf``) for convenience routes under ``*.localhost``.
This is useful for local dashboards (db UI, mail UI, redis UI, etc.).
