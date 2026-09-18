Getting Started
===============

LocalDevStack is a Docker-based XAMPP alternative for PHP and Node.js local development.
The lds CLI manages Compose profiles, local domains, TLS, runtime builds, databases,
admin tools, background jobs, and optional local AI.

Prerequisites
-------------

Install Docker first.

- Docker Engine is preferred on Linux.
- Docker Desktop is supported on Windows and macOS.
- Windows CLI access uses lds.bat with Git Bash.

Quick Start
-----------

Clone the repository and enter it::

   git clone https://github.com/infocyph/LocalDevStack.git
   cd LocalDevStack

On Linux/macOS, prepare the CLI and host permissions::

   chmod +x ./lds
   sudo ./lds setup permissions

Then initialize LocalDevStack and choose optional services::

   ./lds setup init
   ./lds setup profile

Start the stack::

   ./lds up

Create your first local domain::

   ./lds setup domain

The domain wizard asks for the application type and runtime version. PHP and Node
selection remains version-specific; the selected value becomes the runtime image identity.

For browser-trusted HTTPS, install the exported LocalDevStack root CA::

   sudo ./lds certificate install

On Windows, run the same workflow through lds.bat or Git Bash. The permissions
command configures the wrapper path and does not apply Unix chmod logic.

Useful First Checks
-------------------

Show the active convenience URLs::

   lds urls

Show effective infrastructure/runtime image defaults::

   lds images

Run non-destructive diagnostics::

   lds doctor

Validate the effective Compose and scheduler configuration::

   lds config validate

Show effective Compose configuration with secret values redacted::

   lds config show

Use lds config show --raw only when you intentionally need the unredacted output.

Project Layout
--------------

A common layout is::

   project-root/
   ├─ application/
   │  ├─ site1/
   │  ├─ site2/
   │  └─ ...
   └─ LocalDevStack/

Set PROJECT_DIR in docker/.env when your application directory is elsewhere.

LocalDevStack keeps host-managed state under configuration/ and logs/ while
runtime vhosts, certificates, databases, and other service data primarily live in
named Docker volumes.

Next Steps
----------

- Profiles and environment: concepts/profiles-and-env
- Architecture: concepts/architecture
- Storage: concepts/storage-layout
- Domain setup: guides/domain-setup
- TLS: guides/tls-and-certificates
- Local AI: guides/local-ai
- Encrypted secrets: guides/secrets-sops-age
- Notifications: guides/notifications
