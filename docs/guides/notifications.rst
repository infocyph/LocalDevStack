Notifications
=============

LocalDevStack can optionally emit notifications from containers to the host.

Common pattern
--------------

- A small TCP server (often ``notifierd``) runs in the Tools container.
- Other scripts send events (often via a ``notify`` client).
- The host can tail container logs and forward events to OS notifications (toast, notify-send, etc.).

Message format
--------------

Implementations commonly use a single-line, tab-separated payload (token, timeout, urgency, source, title, body).

This is intentionally simple: it survives log streaming and is easy to parse.
