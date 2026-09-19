Ad-hoc Dockerfile Runner
========================

``lds run`` is a small host-side utility for building and running a Dockerfile from the
current directory without adding that project to the main LocalDevStack Compose graph.

It is separate from generated PHP/Node domain runtimes.

Basic Flow
----------

From a directory containing a Dockerfile::

   cd /path/to/project
   lds run

The default action:

1. derives a deterministic project slug from the directory name plus a short path hash;
2. uses ``<slug>:local`` as the default image tag;
3. builds the image only when that tag is not already present;
4. starts a labelled container;
5. mounts the current directory at ``/workspace``;
6. uses ``/workspace`` as the working directory;
7. keeps the container alive with a shell/sleep command by default.

Open a shell::

   lds run shell

The shell command builds/starts first when required, then opens Bash when available or
falls back to ``sh``.

Container Identity
------------------

Default container names look conceptually like::

   lds-run-<directory>-<path-hash>

The path hash prevents same-named projects in different directories from colliding.

Override the name or image tag explicitly::

   lds run --name my-local-container
   lds run --tag my-image
   lds run --tag my-image:dev

When a custom tag has no colon, ``:local`` is appended.

Build Control
-------------

Skip the build step when the required image already exists::

   lds run --no-build

Force a rebuild by removing the managed container/image first::

   lds run rm
   lds run

``lds run rm`` removes the matching managed container and its image.

Container Command vs Keepalive
------------------------------

Default mode replaces the image command with a keepalive shell and disables the image
healthcheck so an unrelated healthcheck does not mark the sleeping development
container unhealthy.

Run the image's normal entrypoint/command instead::

   lds run --no-keepalive

Published Ports
---------------

Publish one or more ports::

   lds run --publish 8080:8080
   lds run -p 8080:8080 -p 9229:9229

Open the first published port in the host browser::

   lds run open

Select a published container port/path::

   lds run open --port 8080 --path /health

Use HTTPS when the exposed service expects it::

   lds run open --port 8443 --https

Extra Mounts
------------

The project directory is always mounted at ``/workspace``.

Add another mount::

   lds run --mount ./data:/data

When the container path is omitted, LocalDevStack mounts the path below ``/mnt`` using
its basename.

Relative host paths are resolved against the current run directory.

Docker Socket Opt-in
--------------------

Grant the container the host Docker socket only when deliberately required::

   lds run --sock

This mounts::

   /var/run/docker.sock:/var/run/docker.sock

Docker socket access is equivalent to powerful host Docker control. Use ``--sock`` only
with trusted Dockerfiles and code.

Host OS
-------

LocalDevStack automatically detects ``linux``, ``macos``, or ``windows`` and exports it
as ``HOST_OS`` inside the ad-hoc container.

Override it when required::

   lds run --host-os linux

Windows/Git Bash path conversion is handled explicitly so host paths and container
``/workspace`` paths are not confused by MSYS rewriting.

Lifecycle Commands
------------------

List all ad-hoc containers managed by this feature::

   lds run ps

Follow logs::

   lds run logs

Stop the current-directory container::

   lds run stop

Remove its container and image::

   lds run rm

Open a shell::

   lds run shell

The ad-hoc runner is intentionally independent from ``lds clean`` and the main
LocalDevStack Compose project.
