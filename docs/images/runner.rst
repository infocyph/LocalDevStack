runner Image
============

Purpose
-------

The Runner image provides background process management and housekeeping:

- ``supervisord`` as PID 1
- cron daemon
- logrotate worker

It is also a convenient place for helper wrappers around ``docker exec``.

Healthcheck
-----------

Runner images commonly expose a healthcheck that verifies supervisor is responsive via ``supervisorctl``.
