Notifications
=============

LocalDevStack can forward notification events emitted inside the trusted Tools container
to the host desktop or terminal.

Host Watcher
------------

Start the watcher::

   lds notify watch

or through the grouped support command::

   lds support notify watch

By default the watcher follows the current project's running ``server-tools`` container.

An explicit container can be supplied for advanced/debug use::

   lds notify watch <container>

Test the path::

   lds notify test "LocalDevStack" "Notification channel works"

Host Behavior
-------------

Linux / WSLg
   Uses ``notify-send`` when available.

Windows/Git Bash or compatible WSL environment
   Uses ``powershell.exe`` to create a Windows toast.

Other environments
   Falls back to a timestamped terminal message when no supported desktop notifier is
   available.

The watcher reconnects if the Docker log stream ends while the container remains
running. It exits when the watched container stops.

Container-side Events
---------------------

Tools-side notification helpers emit a line beginning with::

   __HOST_NOTIFY__

The host watcher consumes those log events and supports timeout, urgency, title, and
body fields.

Normal urgency values are::

   low
   normal
   critical

Application Helpers
-------------------

LocalDevStack/Toolset-based runtime images may expose a small notification helper such as
``docknotify``/``notify`` depending on the runtime image contract.

When available, a typical fire-and-forget application call looks like::

   docknotify -t 2500 -u normal "Job complete" "Background task finished" >/dev/null 2>&1 &

Applications should treat notification delivery as optional observability, not as a
critical execution dependency.

Operational Notes
-----------------

- The watcher requires the target container to be running.
- Docker remains a host-side requirement.
- Desktop delivery depends on the host session and notifier availability.
- Notification payloads travel through container logs; avoid placing credentials,
  tokens, or other sensitive values in titles/bodies.
- Ctrl+C stops the watcher and returns the normal interrupted exit status.
