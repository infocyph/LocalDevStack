apache Image
============

Purpose
-------

The Apache image is used when you run LocalDevStack in Apache mode:

- Nginx terminates HTTP/HTTPS
- Nginx reverse-proxies to Apache
- Apache forwards PHP requests to PHP-FPM (proxy_fcgi)

Why use Apache mode
-------------------

Apache mode is useful if you need Apache-specific behaviors/modules while still keeping Nginx as the edge proxy.
