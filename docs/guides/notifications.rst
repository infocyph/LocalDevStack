Notifications
=============

LocalDevStack can optionally emit notifications from containers to the host (non-Windows).

The idea is simple:

- Your host runs a watcher that listens for notification events.
- Containers fire-and-forget messages using a tiny client binary (``docknotify``).
- The watcher turns those events into desktop notifications (toast / notify-send / etc.).

Host usage (non-Windows)
------------------------

Start watching (recommended during development)::

  lds notify watch

Send a one-off test notification::

  lds notify test "T" "B"

From inside containers (docknotify)
-----------------------------------

Inside LocalDevStack containers, trigger a notification by calling ``docknotify``::

  docknotify -t 2500 -u normal some_title some_body >/dev/null 2>&1 &

Options:

- ``-t``: timeout in milliseconds (example: ``2500``)
- ``-u``: urgency (example: ``low``, ``normal``, ``critical``)
- The final two arguments are: ``title`` and ``body``

The redirection + ``&`` makes it fire-and-forget so it never blocks your request or job.

Common pattern
--------------

- You keep ``lds notify watch`` running on the host.
- Your apps/services inside containers call ``docknotify`` when something noteworthy happens
  (errors, deploy events, background jobs, long tasks, etc.).

Message format
--------------

Notifications are transmitted as a single-line payload (safe for log streaming and easy parsing).
Implementations typically use a tab-separated payload like:

- token
- timeout
- urgency
- source
- title
- body

This is intentionally simple: it survives log streaming and is easy to parse reliably.

PHP example: forward all PHP errors to notifications
----------------------------------------------------

Below is a minimal helper you can drop into any PHP project to log everything to a file and optionally
emit desktop notifications via ``docknotify`` (when running inside LocalDevStack containers).

.. code-block:: php

   <?php

   function registerAllErrorsToFile(string $logFile, bool $notify = false): void
   {
       $dir = \dirname($logFile);
       if (!\is_dir($dir)) {
           @\mkdir($dir, 0775, true);
       }
       if (!\file_exists($logFile)) {
           @\touch($logFile);
       }

       // Log EVERYTHING
       \error_reporting(E_ALL);

       $notifyFn = static function (string $title, string $body) use ($notify): void {
           if (!$notify) {
               return;
           }

           // Require docknotify in PATH
           $bin = \trim((string)@\shell_exec('command -v docknotify 2>/dev/null'));
           if ($bin === '') {
               return;
           }

           // Keep short + safe; remove newlines/tabs to keep one-line protocol stable
           $title = (string)(\preg_replace('/\s+/', ' ', $title) ?? 'PHP Error');
           $body  = (string)(\preg_replace('/\s+/', ' ', $body) ?? '');

           $title = \substr($title, 0, 80);
           $body  = \substr($body, 0, 220);

           // Escape args (no injection)
           $t = \escapeshellarg($title);
           $b = \escapeshellarg($body);

           // Send as "normal" urgency, 2500ms timeout; fire-and-forget
           @\shell_exec($bin . ' -t 2500 -u normal ' . $t . ' ' . $b . ' >/dev/null 2>&1 &');
       };

       $map = [
         E_ERROR             => 'E_ERROR',
         E_WARNING           => 'E_WARNING',
         E_PARSE             => 'E_PARSE',
         E_NOTICE            => 'E_NOTICE',
         E_CORE_ERROR        => 'E_CORE_ERROR',
         E_CORE_WARNING      => 'E_CORE_WARNING',
         E_COMPILE_ERROR     => 'E_COMPILE_ERROR',
         E_COMPILE_WARNING   => 'E_COMPILE_WARNING',
         E_USER_ERROR        => 'E_USER_ERROR',
         E_USER_WARNING      => 'E_USER_WARNING',
         E_USER_NOTICE       => 'E_USER_NOTICE',
         E_RECOVERABLE_ERROR => 'E_RECOVERABLE_ERROR',
         E_DEPRECATED        => 'E_DEPRECATED',
         E_USER_DEPRECATED   => 'E_USER_DEPRECATED',
       ];

       // Log non-fatal errors (warnings/notices/deprecations, etc.)
       \set_error_handler(
         static function (int $severity, string $message, string $file, int $line) use ($logFile, $map, $notifyFn): bool {
             // Respect @ suppression
             if (!(error_reporting() & $severity)) {
                 return true;
             }

             $label = $map[$severity] ?? ('E_' . (string)$severity);
             $ts = \date('Y-m-d H:i:s');

             @\file_put_contents(
               $logFile,
               $ts . ' [' . $label . '] ' . $message . ' in ' . $file . ':' . $line . PHP_EOL,
               FILE_APPEND | LOCK_EX
             );

             $notifyFn($label, $message . ' (' . \basename($file) . ':' . $line . ')');

             // We handled it; do not let PHP print/log elsewhere
             return true;
         }
       );

       // Log uncaught exceptions / TypeErrors, etc.
       \set_exception_handler(
         static function (\Throwable $e) use ($logFile, $notifyFn): void {
             $ts = \date('Y-m-d H:i:s');
             $type = \get_class($e);

             $msg = $ts
               . ' [UNCAUGHT ' . $type . '] '
               . $e->getMessage()
               . ' in ' . $e->getFile() . ':' . $e->getLine()
               . PHP_EOL
               . $e->getTraceAsString()
               . PHP_EOL;

             @\file_put_contents($logFile, $msg . PHP_EOL, FILE_APPEND | LOCK_EX);

             $notifyFn(
               'UNCAUGHT ' . $type,
               $e->getMessage() . ' (' . \basename($e->getFile()) . ':' . $e->getLine() . ')'
             );

             exit(255);
         }
       );

       // Log fatal errors (E_ERROR, E_PARSE, E_COMPILE_ERROR, etc.)
       \register_shutdown_function(
         static function () use ($logFile, $notifyFn, $map): void {
             $err = \error_get_last();
             if ($err === null) {
                 return;
             }

             $fatalTypes = [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR];
             $type = (int)($err['type'] ?? 0);

             if (!\in_array($type, $fatalTypes, true)) {
                 return;
             }

             $label = $map[$type] ?? ('E_' . (string)$type);
             $ts = \date('Y-m-d H:i:s');

             $message = (string)($err['message'] ?? '');
             $file = (string)($err['file'] ?? '');
             $line = (int)($err['line'] ?? 0);

             @\file_put_contents(
               $logFile,
               $ts . ' [' . $label . '] ' . $message . ' in ' . $file . ':' . $line . PHP_EOL,
               FILE_APPEND | LOCK_EX
             );

             $notifyFn($label, $message . ' (' . \basename($file) . ':' . $line . ')');
         }
       );

       // Ensure nothing is printed to screen by PHP itself
       \ini_set('display_errors', '0');
       \ini_set('log_errors', '0');
   }

   // Usage:
   $log = __DIR__ . '/php-upg-err-' . \date('Ymd') . '.log';
   registerAllErrorsToFile($log, true);

Node.js example: send notifications using docknotify
----------------------------------------------------

LocalDevStack ships ``docknotify`` inside Node containers too, so Node apps can emit host notifications
without extra dependencies.

Below is a small helper that:

- checks ``docknotify`` exists
- strips newlines/tabs (keeps the one-line protocol stable)
- sends a fire-and-forget notification (non-blocking)

.. code-block:: js

   // docknotify.js
   const { spawnSync, spawn } = require("node:child_process");

   // Cache existence check so we don't run it per request
   const HAS_DOCKNOTIFY = (() => {
     const r = spawnSync("sh", ["-lc", "command -v docknotify >/dev/null 2>&1"], { stdio: "ignore" });
     return r.status === 0;
   })();

   function clean(s, max) {
     return String(s ?? "")
       .replace(/[\t\r\n]+/g, " ")
       .replace(/\s+/g, " ")
       .trim()
       .slice(0, max);
   }

   function notify(title, body, { timeout = 2500, urgency = "normal" } = {}) {
     if (!HAS_DOCKNOTIFY) return;

     const t = clean(title, 80) || "Node";
     const b = clean(body, 220);

     // Fire-and-forget: no stdout/stderr, detached, unref
     const child = spawn(
       "docknotify",
       ["-t", String(timeout), "-u", urgency, t, b],
       { stdio: "ignore", detached: true }
     );

     child.on("error", () => {});
     child.unref();
   }

   module.exports = { notify };

.. code-block:: js

   // example usage (Express)
   const express = require("express");
   const { notify } = require("./docknotify");

   const app = express();

   process.on("unhandledRejection", (err) => {
     notify("Unhandled Rejection", err?.stack || String(err));
   });

   process.on("uncaughtException", (err) => {
     notify("Uncaught Exception", err?.stack || String(err), { urgency: "critical" });
     // process.exit(1);
   });

   app.get("/", (req, res) => res.json({ ok: true }));

   // test route
   app.get("/boom", () => {
     throw new Error("Test error from /boom");
   });

   // eslint-disable-next-line no-unused-vars
   app.use((err, req, res, next) => {
     notify("Express Error", `${err.message} (${req.method} ${req.originalUrl})`);
     res.status(500).json({ error: "Internal Server Error" });
   });

   const port = process.env.PORT || 3000;
   app.listen(port, () => {
     notify("Node Started", `Listening on :${port}`, { timeout: 1500, urgency: "low" });
   });

Quick test
~~~~~~~~~~

1. On host, start watcher::

     lds notify watch

2. Trigger the test route::

     curl -sS http://your-domain.localhost/boom >/dev/null

Practical workflow
------------------

1. On your host, keep this running in a terminal::

     lds notify watch

2. In your PHP/Node apps (inside containers), trigger ``docknotify`` on important events
   (errors, failed jobs, timeouts, etc.).

This gives you immediate feedback without tailing logs all day.
